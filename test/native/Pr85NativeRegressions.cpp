// TASK-ONLY: compiled instead of DriverTransaction.cpp in a disposable source copy.
// The real implementation is included unchanged. Only MSI diagnostic logging is suppressed;
// SCM/SetupAPI calls, comparisons and the inverse are the production functions.
#include "stdafx.h"
#define WcaLog(...) ((void)0)
#include "DriverTransaction.cpp"
#undef WcaLog
#include <cstdio>

namespace {
struct OwnedService {
    SC_HANDLE handle = NULL;
    std::wstring name;
    ~OwnedService() { if (handle) { DeleteService(handle); CloseServiceHandle(handle); } }
    HRESULT Remove(SC_HANDLE scm) {
        if (!handle) return S_OK;
        if (!DeleteService(handle)) return HRESULT_FROM_WIN32(GetLastError());
        CloseServiceHandle(handle); handle = NULL;
        SC_HANDLE remaining = OpenServiceW(scm, name.c_str(), SERVICE_QUERY_CONFIG);
        if (remaining) { CloseServiceHandle(remaining); return HRESULT_FROM_WIN32(ERROR_INVALID_STATE); }
        return GetLastError() == ERROR_SERVICE_DOES_NOT_EXIST ? S_OK : HRESULT_FROM_WIN32(GetLastError());
    }
};
struct ResultLog {
    FILE* file = NULL;
    unsigned passed = 0, failed = 0;
    ~ResultLog() { if (file) fclose(file); }
    bool Check(bool okay, const char* label, HRESULT error = S_OK) {
        if (file) { fprintf(file, "%s\t%s\t0x%08lx\n", okay ? "PASS" : "FAIL", label, static_cast<unsigned long>(error)); fflush(file); }
        okay ? ++passed : ++failed;
        return okay;
    }
};
HRESULT SetConfig(SC_HANDLE service, const DriverServiceConfig& c) {
    std::vector<WCHAR> deps;
    for (const auto& d : c.dependencies) { deps.insert(deps.end(), d.begin(), d.end()); deps.push_back(0); }
    if (deps.empty()) deps.push_back(0);
    deps.push_back(0);
    return ChangeServiceConfigW(service, c.type, c.start, c.error, c.imagePath.c_str(), c.loadOrderGroup.c_str(),
        NULL, deps.data(), NULL, NULL, NULL) ? S_OK : HRESULT_FROM_WIN32(GetLastError());
}
HRESULT WriteFixture(const std::wstring& path, const std::string& body) {
    HANDLE f = CreateFileW(path.c_str(), GENERIC_WRITE, 0, NULL, CREATE_NEW, FILE_ATTRIBUTE_NORMAL, NULL);
    if (f == INVALID_HANDLE_VALUE) return HRESULT_FROM_WIN32(GetLastError());
    DWORD written = 0;
    BOOL okay = WriteFile(f, body.data(), static_cast<DWORD>(body.size()), &written, NULL);
    DWORD error = okay && written == body.size() ? ERROR_SUCCESS : (GetLastError() ? GetLastError() : ERROR_WRITE_FAULT);
    CloseHandle(f); return HRESULT_FROM_WIN32(error);
}
std::string Ascii(const std::wstring& value) {
    return std::string(value.begin(), value.end()); // generated fixture names contain ASCII only
}
HRESULT Snapshot(SC_HANDLE service, const std::wstring& name, DriverServiceConfig& c) {
    c.name = name; return QueryDriverService(service, c);
}
HRESULT Exercise(SC_HANDLE service, const std::wstring& name, const DriverServiceConfig& wanted,
    const char* label, ResultLog& log) {
    HRESULT hr = SetConfig(service, wanted);
    if (!log.Check(SUCCEEDED(hr), label, hr)) return hr;
    DriverServiceConfig before;
    hr = Snapshot(service, name, before);
    if (FAILED(hr)) return hr;
    DriverServiceConfig changed = before;
    changed.imagePath += L" /changed";
    changed.loadOrderGroup = L"Pr85ReviewNativeGroup";
    changed.type = SERVICE_WIN32_SHARE_PROCESS;
    changed.start = SERVICE_AUTO_START;
    changed.error = SERVICE_ERROR_IGNORE;
    changed.dependencies = before.dependencies.empty() ? std::vector<std::wstring>{L"EventLog"} : std::vector<std::wstring>{};
    hr = SetConfig(service, changed);
    if (!log.Check(SUCCEEDED(hr), "SCM mutation B accepted (never started)", hr)) return hr;
    DriverServiceConfig drifted;
    hr = Snapshot(service, name, drifted);
    if (!log.Check(SUCCEEDED(hr) && !SameDriverService(before, drifted), "SCM B differs from captured A", hr)) return FAILED(hr) ? hr : E_FAIL;
    hr = RestoreDriverService(before); // actual production inverse
    if (!log.Check(SUCCEEDED(hr), "production RestoreDriverService returned success", hr)) return hr;
    DriverServiceConfig after;
    hr = Snapshot(service, name, after);
    if (!log.Check(SUCCEEDED(hr) && SameDriverService(before, after), "SCM A restored including dependencies and tracked fields", hr)) return FAILED(hr) ? hr : E_FAIL;
    return S_OK;
}
}

extern "C" UINT __stdcall Pr85RunNativeRegressions(PCWSTR directory) {
    if (!directory || !*directory) return ERROR_INVALID_PARAMETER;
    ResultLog log;
    std::wstring root(directory);
    if (_wfopen_s(&log.file, (root + L"\\native-results.tsv").c_str(), L"wb")) return ERROR_OPEN_FAILED;
    SC_HANDLE scm = OpenSCManagerW(NULL, NULL, SC_MANAGER_CREATE_SERVICE | SC_MANAGER_CONNECT);
    if (!scm) { log.Check(false, "open SCM", HRESULT_FROM_WIN32(GetLastError())); return ERROR_ACCESS_DENIED; }
    OwnedService dependency, subject;
    WCHAR suffix[80]; swprintf_s(suffix, L"_%lu_%llu", GetCurrentProcessId(), static_cast<unsigned long long>(GetTickCount64()));
    dependency.name = std::wstring(L"Pr85ReviewNativeDep") + suffix;
    subject.name = std::wstring(L"Pr85ReviewNativeSvc") + suffix;
    WCHAR system[MAX_PATH] = {}; UINT length = GetSystemDirectoryW(system, ARRAYSIZE(system));
    HRESULT hr = length && length < ARRAYSIZE(system) ? S_OK : E_FAIL;
    std::wstring image = std::wstring(L"\"") + system + L"\\cmd.exe\" /c exit 0";
    if (SUCCEEDED(hr)) {
        dependency.handle = CreateServiceW(scm, dependency.name.c_str(), dependency.name.c_str(), SERVICE_ALL_ACCESS,
            SERVICE_WIN32_OWN_PROCESS, SERVICE_DEMAND_START, SERVICE_ERROR_NORMAL, image.c_str(), NULL, NULL, NULL, NULL, NULL);
        if (!dependency.handle) hr = HRESULT_FROM_WIN32(GetLastError());
    }
    if (SUCCEEDED(hr)) {
        subject.handle = CreateServiceW(scm, subject.name.c_str(), subject.name.c_str(), SERVICE_ALL_ACCESS,
            SERVICE_WIN32_OWN_PROCESS, SERVICE_DEMAND_START, SERVICE_ERROR_NORMAL, image.c_str(), NULL, NULL, NULL, NULL, NULL);
        if (!subject.handle) hr = HRESULT_FROM_WIN32(GetLastError());
    }
    log.Check(SUCCEEDED(hr), "create unique test-owned services only", hr);
    DriverServiceConfig wanted;
    if (SUCCEEDED(hr)) hr = Snapshot(subject.handle, subject.name, wanted);
    if (SUCCEEDED(hr)) { wanted.dependencies = {dependency.name}; hr = Exercise(subject.handle, subject.name, wanted, "nonempty dependency snapshot", log); }
    if (SUCCEEDED(hr)) { wanted.dependencies.clear(); hr = Exercise(subject.handle, subject.name, wanted, "empty dependency snapshot (must clear B)", log); }
    if (SUCCEEDED(hr)) { wanted.dependencies = {dependency.name, L"+Base"}; hr = Exercise(subject.handle, subject.name, wanted, "service plus load-order-group dependency snapshot", log); }

    const std::string header = "[Version]\r\nSignature=\"$WINDOWS NT$\"\r\nClass=System\r\nClassGuid={4d36e97d-e325-11ce-bfc1-08002be10318}\r\n";
    std::vector<std::wstring> fixtures;
    auto fixture = [&](PCWSTR file, const std::string& content) -> std::wstring {
        std::wstring path = root + L"\\" + file;
        HRESULT result = WriteFixture(path, header + content);
        if (FAILED(result)) { hr = result; log.Check(false, "write CREATE_NEW task-owned INF fixture", result); }
        else fixtures.push_back(path);
        return path;
    };
    if (SUCCEEDED(hr)) {
        auto path = fixture(L"needs-existing.inf", "[Root.Services]\r\nNeeds=Nested.Services\r\n[Nested.Services]\r\nAddService=" + Ascii(subject.name) + ",0,Unused.Service\r\n");
        std::vector<std::wstring> names;
        if (SUCCEEDED(hr)) hr = CaptureDriverServiceNames(path.c_str(), L"Root.Services", names);
        if (!log.Check(SUCCEEDED(hr) && names.size() == 1 && DriverInfNamePresent(names, subject.name), "actual SetupAPI Needs reaches existing test-owned service", hr)) hr = E_FAIL;
        if (SUCCEEDED(hr)) { wanted.dependencies = {dependency.name}; hr = Exercise(subject.handle, names[0], wanted, "Needs-discovered service configuration inverse", log); }
    }
    if (SUCCEEDED(hr)) {
        auto path = fixture(L"needs-inbox.inf", "[Root.Services]\r\nInclude=mf.inf\r\nNeeds=MFINSTALL.mf.Services\r\n");
        std::vector<std::wstring> names;
        HRESULT result = SUCCEEDED(hr) ? CaptureDriverServiceNames(path.c_str(), L"Root.Services", names) : hr;
        if (!log.Check(SUCCEEDED(result) && DriverInfNamePresent(names, L"mf"), "actual SetupAPI system mf.inf Include/Needs read only", result)) hr = E_FAIL;
    }
    if (SUCCEEDED(hr)) {
        DriverServiceConfig before; hr = Snapshot(subject.handle, subject.name, before);
        struct Bad { PCWSTR file; const char* body; const char* label; } cases[] = {
            {L"needs-cycle.inf", "[Root.Services]\r\nNeeds=Again.Services\r\n[Again.Services]\r\nNeeds=Root.Services\r\n", "cycle refused"},
            {L"needs-missing.inf", "[Root.Services]\r\nNeeds=Absent.Services\r\n", "missing explicit Needs refused"},
            {L"include-missing.inf", "[Root.Services]\r\nInclude=Pr85ReviewDefinitelyAbsent.inf\r\n", "missing system Include refused"},
            {L"needs-delete.inf", "[Root.Services]\r\nDelService=Pr85ReviewNeverDelete\r\n", "destructive directive refused"}
        };
        for (const auto& c : cases) {
            auto path = fixture(c.file, c.body); if (FAILED(hr)) break;
            std::vector<std::wstring> names;
            HRESULT result = CaptureDriverServiceNames(path.c_str(), L"Root.Services", names);
            DriverServiceConfig after; HRESULT query = Snapshot(subject.handle, subject.name, after);
            if (!log.Check(FAILED(result) && SUCCEEDED(query) && SameDriverService(before, after), c.label, result)) hr = E_FAIL;
        }
    }
    // Always try deleting only services created by this invocation; never open/delete an existing name.
    HRESULT cleanupSubject = subject.Remove(scm);
    HRESULT cleanupDependency = dependency.Remove(scm);
    log.Check(SUCCEEDED(cleanupSubject), "test-owned subject removed", cleanupSubject);
    log.Check(SUCCEEDED(cleanupDependency), "test-owned dependency removed", cleanupDependency);
    CloseServiceHandle(scm);
    for (const auto& path : fixtures) if (!DeleteFileW(path.c_str())) log.Check(false, "remove own INF fixture", HRESULT_FROM_WIN32(GetLastError()));
    log.Check(SUCCEEDED(hr), "complete native regression sequence", hr);
    fprintf(log.file, "TOTAL\tpassed=%u\tfailed=%u\n", log.passed, log.failed); fflush(log.file);
    return log.failed ? ERROR_INSTALL_FAILURE : ERROR_SUCCESS;
}
