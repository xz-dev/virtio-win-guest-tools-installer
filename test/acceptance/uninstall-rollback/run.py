#!/usr/bin/env python3
"""One task-only delivery check: cancel removal of an owned balloon package, then verify its inverse.
No guest is contacted until the prior full-suite receipt confirms both authorized suites finished.
"""
import argparse
import base64
import hashlib
import json
import ntpath
import re
import sys
import uuid
from pathlib import Path


class NotCovered(RuntimeError):
    pass


def quote(value):
    return "'" + str(value).replace("'", "''") + "'"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--arch', required=True, choices=('x64', 'x86'))
    parser.add_argument('--acceptance-dir', required=True, type=Path)
    parser.add_argument('--msi', required=True, type=Path)
    parser.add_argument('--build-receipt', required=True, type=Path)
    parser.add_argument('--prior-suite-receipt', required=True, type=Path)
    parser.add_argument('--healthy-snapshot', required=True)
    parser.add_argument('--output', required=True, type=Path, help='Fresh immutable directory for this single run')
    parser.add_argument('--allow-guest-mutation', action='store_true')
    args = parser.parse_args()
    if not args.allow_guest_mutation:
        parser.error('Explicit --allow-guest-mutation is required for this disposable guest check')
    suites = json.loads(args.prior_suite_receipt.read_text())
    if any(a not in suites or suites[a].get('exit') != 0 or not suites[a].get('end') for a in ('x64', 'x86')):
        parser.error('Both complete prior suites must have finished successfully; do not overlap VM owners')
    if Path(suites[args.arch].get('newMsi', '')).resolve() != args.msi.resolve() or suites[args.arch].get('healthy') != args.healthy_snapshot:
        parser.error('Prior completed suite must name this exact candidate path and healthy snapshot')
    digest = hashlib.sha256(args.msi.read_bytes()).hexdigest()
    builds = json.loads(args.build_receipt.read_text(encoding='utf-8-sig'))
    if not any(b.get('kind') == 'msi' and b.get('arch') == args.arch and b.get('version') == '0.1.350'
               and b.get('file') == args.msi.name and b.get('sha256', '').lower() == digest for b in builds):
        parser.error('MSI must be the exact frozen 0.1.350 candidate in the supplied build receipt')
    sys.path.insert(0, str(args.acceptance_dir.resolve()))
    from machine import from_environment, GUEST_DIR
    vm = from_environment()
    if vm is None or vm.domain != {'x64': 'win-test', 'x86': 'win-test-x86'}[args.arch]:
        parser.error('Set PR85_VM/PR85_SSH for the matching authorized guest; no other domain is accepted')
    args.output.mkdir(parents=True, exist_ok=False)
    result = {'arch': args.arch, 'msi': str(args.msi), 'sha256': digest, 'passed': False,
              'scope': 'owned balloon feature removal cancelled at its post-forward progress increment, then verify binding/configuration inverse'}
    nonce = uuid.uuid4().hex
    remote_helper = GUEST_DIR + '\\CancelAfter-' + nonce + '.cs'
    remote_log = GUEST_DIR + '\\owned-uninstall-' + nonce + '.log'
    remote_trace = GUEST_DIR + '\\owned-uninstall-' + nonce + '.tsv'
    pending, installed, customised, original, service, helper_loaded = False, False, False, None, None, False
    exit_code = 1

    def guest_text(path, destination):
        encoded = vm.powershell('[Convert]::ToBase64String([IO.File]::ReadAllBytes(' + quote(path) + '))')
        data = base64.b64decode(encoded)
        (args.output / destination).write_bytes(data)
        return data.decode('utf-16' if data.startswith((b'\xff\xfe', b'\xfe\xff')) else 'utf-8-sig', errors='replace')

    def service_read():
        # Add-Type is per SSH PowerShell process; reuse the same task helper, never production files.
        return json.loads(vm.powershell('Add-Type -Path ' + quote(remote_helper) + '; '
                          '[Pr85ServiceObservation]::Read(' + quote(service) + ') | ConvertTo-Json -Depth 4 -Compress'))

    def service_start(value):
        vm.powershell('Add-Type -Path ' + quote(remote_helper) + '; '
                      '[Pr85ServiceObservation]::SetNonBootStart(' + quote(service) + ',' + str(value) + ')')

    try:
        vm.start_from(args.healthy_snapshot)
        vm.copy_in(Path(__file__).with_name('CancelAfter.cs'), remote_helper)
        helper_loaded = True
        pending = True
        code = vm.install(args.msi)
        pending = False
        result['fixtureInstallExit'] = code
        if code not in (0, 3010):
            raise AssertionError('Candidate fixture installation failed')
        installed = True
        install_log = GUEST_DIR + '\\' + f'{vm.step:02d}-{args.msi.stem}.log'
        vm.reboot()
        initial = vm.observe()
        balloon = [(key, value) for key, value in initial['devices'].items()
                   if value.get('service', '').casefold() == 'balloon']
        if len(balloon) != 1 or balloon[0][1].get('status') != 'OK':
            raise NotCovered('One healthy balloon device is required; no other device or service is substituted')
        device, binding = balloon[0]
        service = binding['service']
        published = vm.powershell('(Get-PnpDeviceProperty -InstanceId ' + quote(device)
                                 + ' -KeyName DEVPKEY_Device_DriverInfPath -ErrorAction Stop).Data')
        text = guest_text(install_log, 'fixture-install.log')
        stages = re.findall(r'Driver stage: component=(\S+) published=(.*?) createdByThisCall=(\d+)', text)
        created = [(component, path) for component, path, flag in stages
                   if flag == '1' and ntpath.basename(path.strip()).casefold() == published.casefold()]
        if len(created) != 1:
            raise NotCovered('No unique live staging creation result ties this device to a package created by the candidate')
        component, source_published = created[0]
        result['ownedPackageEvidence'] = {'component': component, 'publishedInf': published,
                                         'stagedPublished': source_published, 'device': device}
        original = service_read()
        if original['Type'] != 1 or original['Start'] in (0, 1):
            raise NotCovered('Balloon fixture is not a non-boot/non-system kernel service; no configuration changed')
        customised = True
        service_start(2)
        custom = service_read()
        if custom['Start'] != 2:
            raise AssertionError('The test-only automatic-start customization did not take effect')
        before = vm.observe()
        result['originalService'] = original
        result['beforeService'] = custom
        result['before'] = before
        remote_msi = GUEST_DIR + '\\' + args.msi.name
        pending = True
        outcome = json.loads(vm.powershell('Add-Type -Path ' + quote(remote_helper) + '; '
                 '[MsiCancelAfter]::Run(' + ','.join(quote(v) for v in (remote_msi,
                 'REMOVE=FE_balloon_driver REBOOT=ReallySuppress', component,
                 remote_log, remote_trace)) + ') | ConvertTo-Json -Depth 4 -Compress'))
        pending = False
        result['cancel'] = outcome
        log = guest_text(remote_log, 'cancelled-feature-removal.log')
        guest_text(remote_trace, 'actions.tsv')
        if outcome['ExitCode'] not in (0, 1602, 3010):
            raise AssertionError('MSI returned an unexpected failure instead of the requested cancellation')
        if not outcome['Armed'] or not outcome['Cancelled'] or outcome['ExitCode'] != 1602:
            raise NotCovered('The owned INFO marker followed by its successful-forward progress increment was not cancelled; see UI trace and actual exit')
        gates = {
            'ownedRemovalAttempt': re.search(r'Driver uninstall: component=' + re.escape(component) + r' knownCreatedPackage=1\.', log) is not None,
            'completionProgress': (outcome.get('RemovalInfoSeen') and outcome.get('CompletionProgressSeen')
                                   and not outcome.get('CompletionAborted')
                                   and outcome.get('Boundary') == 'owned-removal-info-then-progress'
                                   and outcome.get('CancelProgressKind') == 2
                                   and outcome.get('CancelProgressTicks') == 200000),
            'bindingReinstalled': ('Verified prior binding restored: ' + device).casefold() in log.casefold(),
            'customServiceInverse': ('Verified prior service configuration restored: ' + service).casefold() in log.casefold(),
            'rollbackAction': 'RollbackUninstall' in outcome['Actions'],
        }
        result['pathGates'] = gates
        vm.reboot()
        result['afterService'] = service_read()
        result['after'] = vm.observe()
        if result['afterService'] != custom:
            raise AssertionError('Cancelled owned-package removal did not restore the customized service configuration')
        if result['after'] != before:
            raise AssertionError('Cancelled removal changed public products/packages/bindings/files/service observations')
        if not all(gates.values()):
            raise NotCovered('Delivery state restored, but actual removal/binding-reinstall/configuration-inverse path was not fully observed')
        result['passed'] = True
        exit_code = 0
    except NotCovered as error:
        result['notCovered'] = str(error)
        exit_code = 2
    except BaseException as error:
        result['error'] = type(error).__name__ + ': ' + str(error)
        exit_code = 3 if getattr(vm, 'auth_failed', False) else 1
    finally:
        result['pendingOperation'] = pending
        if not getattr(vm, 'auth_failed', False) and not pending:
            try:
                if helper_loaded and customised and original is not None and service is not None:
                    service_start(original['Start'])
                    result['serviceStartRestored'] = service_read()['Start'] == original['Start']
                    if not result['serviceStartRestored']:
                        raise RuntimeError('The test-only start-mode customization was not restored')
                if installed:  # Never issue another installer when the first one's status is unknown.
                    pending = True
                    result['cleanupExit'] = vm.uninstall(args.msi)
                    pending = False
                    if result['cleanupExit'] not in (0, 3010):
                        raise RuntimeError('Candidate cleanup failed; preserve current state for inspection')
                    vm.reboot()
                    result['cleanupState'] = vm.observe()
                    if result['cleanupState']['products']:
                        raise RuntimeError('Virtio product registration remains after candidate cleanup')
                vm.shutdown()
            except BaseException as error:
                result['cleanupError'] = type(error).__name__ + ': ' + str(error)
                result['passed'] = False
                exit_code = 3 if getattr(vm, 'auth_failed', False) else 1
        else:
            result['cleanupSkipped'] = 'Authentication failure or unknown installer completion; no additional guest operation was started'
        result['pendingOperation'] = pending
        (args.output / 'result.json').write_text(json.dumps(result, indent=2))
    print(json.dumps({'passed': result['passed'], 'exit': exit_code, 'result': str(args.output / 'result.json'),
                      'notCovered': result.get('notCovered'), 'error': result.get('error'), 'cleanupError': result.get('cleanupError')}))
    return exit_code


if __name__ == '__main__':
    raise SystemExit(main())
