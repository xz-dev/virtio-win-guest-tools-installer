#include "../src/DrvInst/DrvInstCA/DriverTransaction.h"
#include <cassert>
#include <cwctype>

int main()
{
    DriverUndoRecord before;
    before.sourceInf = L"C:\\Program Files\\Virtio-Win\\Viorng\\viorng.inf";
    before.component = L"{00000000-0000-0000-0000-000000000001}";
    before.metadataKey = L"SOFTWARE\\RedHat\\Virtio-Win\\Components\\" + before.component;
    before.sourcePackage = { before.sourceInf, L"inf-sha256", L"catalog-sha256" };
    before.metadata.keyPresent = true;
    before.metadata.redHatPresent = before.metadata.virtioPresent = before.metadata.componentsPresent = true;
    before.metadata.oem = { true, L"oem19.inf" };
    before.metadata.infHash = { true, std::wstring(64, L'a') };
    before.metadata.catalogHash = { true, std::wstring(64, L'b') };
    before.metadata.strongname = { true, L"C:\\Windows\\System32\\DriverStore\\previous.inf" };
    DriverBinding bound;
    bound.instance = L"PCI\\existing";
    bound.hasDriver = true;
    bound.package = { L"C:\\Windows\\System32\\DriverStore\\previous.inf", L"old-inf", L"old-cat" };
    bound.section = L"Install";
    bound.sectionExt = L".NTamd64";
    before.bindings.push_back(bound);
    DriverBinding unbound;
    unbound.instance = L"PCI\\null-driver";
    before.bindings.push_back(unbound);
    std::vector<std::wstring> encoded;
    EncodeDriverSnapshot(before, encoded);
    DriverUndoRecord decoded;
    assert(DecodeDriverSnapshot(encoded, decoded));
    std::vector<std::wstring> roundTrip;
    EncodeDriverSnapshot(decoded, roundTrip);
    assert(roundTrip == encoded);
    assert(decoded.metadata.keyPresent && decoded.metadata.oem.present);
    assert(!decoded.metadata.createdByComponent.present);
    assert(KnownDriverPackageIdentity(MetadataPackageIdentity(decoded.metadata)));
    assert(decoded.bindings.size() == 2 && !decoded.bindings[1].hasDriver);
    assert(decoded.bindings[0].sectionExt == L".NTamd64");
    // Captured AddService configuration round-trips; malformed service fields are rejected.
    DriverUndoRecord withService = before;
    DriverServiceConfig service;
    service.name = L"BALLOON"; service.imagePath = L"\\SystemRoot\\System32\\drivers\\balloon.sys";
    service.type = 1; service.start = 3; service.error = 1; service.loadOrderGroup = L"Extended Base";
    withService.services.push_back(service);
    EncodeDriverSnapshot(withService, encoded);
    assert(DecodeDriverSnapshot(encoded, decoded) && decoded.services.size() == 1);
    assert(decoded.services[0].imagePath == service.imagePath && decoded.services[0].start == 3);
    assert(decoded.services[0].loadOrderGroup == L"Extended Base");
    encoded.back() = L"x";
    assert(!DecodeDriverSnapshot(encoded, decoded));
    EncodeDriverSnapshot(withService, encoded);
    encoded[encoded.size() - 5] = L""; // empty ImagePath
    assert(!DecodeDriverSnapshot(encoded, decoded));
    EncodeDriverSnapshot(withService, encoded);
    encoded.pop_back();
    assert(!DecodeDriverSnapshot(encoded, decoded));

    DriverPackageIdentity staged { L"C:\\Windows\\System32\\DriverStore\\new.inf", L"inf-sha256", L"catalog-sha256" };
    // ERROR_FILE_EXISTS: preserve preexisting package; no invented created-resource ownership.
    assert(RecordDriverStage(decoded, false, staged, L"oem42.inf"));
    assert(decoded.stageKnown && !decoded.packageCreated);
    assert(!RecordDriverStage(decoded, true, staged, L"oem42.inf"));
    DriverUndoRecord created = before;
    assert(RecordDriverStage(created, true, staged, L"oem43.inf") && created.packageCreated);
    DriverUndoRecord wrong = before;
    staged.catalogHash = L"different-signed-package";
    assert(!RecordDriverStage(wrong, true, staged, L"oem44.inf"));
    assert(!wrong.stageKnown);

    DriverUndoRecord noHardware = before;
    noHardware.bindings.clear();
    noHardware.metadata = DriverMetadata();
    EncodeDriverSnapshot(noHardware, encoded);
    assert(DecodeDriverSnapshot(encoded, decoded) && decoded.bindings.empty());
    staged.catalogHash = L"catalog-sha256";
    assert(RecordDriverStage(decoded, true, staged, L"oem45.inf"));
    EncodeDriverSnapshot(before, encoded);
    encoded.pop_back();
    assert(!DecodeDriverSnapshot(encoded, decoded));
    EncodeDriverSnapshot(before, encoded);
    encoded[23] = L"4294967296";
    assert(!DecodeDriverSnapshot(encoded, decoded));
    unsigned number;
    assert(!DriverStateNumber(L"-1", number));
    assert(!DriverStateNumber(L"1junk", number));
    assert(DriverStateNumber(L"0", number) && number == 0);
    // No present device updated is staged-only success; every other DiInstallDriverW failure stays fatal.
    assert(DriverPackageInstallAccepted(true, 0));
    assert(DriverPackageInstallAccepted(false, DriverNoDeviceUpdated));
    assert(!DriverPackageInstallAccepted(false, 0));
    assert(!DriverPackageInstallAccepted(false, 5));
    assert(!DriverPackageInstallAccepted(false, 2));
    // A stale package reference is NULL-driver only for a non-present node and only for not-found errors.
    assert(DriverStalePhantomBinding(false, static_cast<std::int32_t>(0x80070002)));
    assert(DriverStalePhantomBinding(false, static_cast<std::int32_t>(0x80070003)));
    assert(!DriverStalePhantomBinding(true, static_cast<std::int32_t>(0x80070002)));
    assert(!DriverStalePhantomBinding(false, static_cast<std::int32_t>(0x80070005)));
    // Scope: present matches plus phantom children of present matches, parent-first; other phantoms excluded.
    auto ieq = [](const wchar_t* a, const wchar_t* b) {
        for (; *a && *b; ++a, ++b) if (towlower(*a) != towlower(*b)) return false;
        return *a == *b;
    };
    auto node = [](const wchar_t* id, const wchar_t* parent, bool present) {
        DriverScopeNode n; n.binding.instance = id; n.parent = parent; n.present = present; return n;
    };
    std::vector<DriverScopeNode> nodes = {
        node(L"VIOINPUT\\CHILD", L"pci\\parent", false),   // revivable phantom child
        node(L"PCI\\OTHER", L"ROOT", true),
        node(L"PCI\\PARENT", L"ROOT", true),
        node(L"PCI\\STALE", L"ROOT", false),               // unrelated phantom: never in scope
        node(L"HID\\ORPHAN", L"VIOINPUT\\CHILD", false) }; // phantom under a phantom: not revivable here
    std::vector<DriverBinding> scope;
    assert(BuildDriverBindingScope(nodes, ieq, scope));
    assert(scope.size() == 3);
    assert(scope[0].instance == L"PCI\\OTHER" && scope[1].instance == L"PCI\\PARENT");
    assert(scope[2].instance == L"VIOINPUT\\CHILD");
    // Present grandchild chain is ordered by depth.
    std::vector<DriverScopeNode> chain = { node(L"C", L"B", true), node(L"B", L"A", true), node(L"A", L"", true) };
    assert(BuildDriverBindingScope(chain, ieq, scope));
    assert(scope[0].instance == L"A" && scope[1].instance == L"B" && scope[2].instance == L"C");
    // A parent cycle among in-scope nodes refuses (caller fails before mutation).
    std::vector<DriverScopeNode> loop = { node(L"A", L"B", true), node(L"B", L"A", true) };
    assert(!BuildDriverBindingScope(loop, ieq, scope));
}
