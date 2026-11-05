#include "../src/DrvInst/DrvInstCA/DriverTransaction.h"
#include <cassert>
#include <map>

static void Frame(std::wstring& text, const std::vector<std::wstring>& values)
{
    auto field = [&](const std::wstring& value) { if (!text.empty()) text.push_back(128); text += value; };
    field(std::to_wstring(values.size()));
    for (const auto& value : values) field(value);
    field(L"complete");
}

static std::vector<unsigned char> Bytes(const std::wstring& text)
{
    std::vector<unsigned char> bytes;
    for (wchar_t c : text) { assert(c <= 65535); bytes.push_back(c & 255); bytes.push_back((c >> 8) & 255); }
    return bytes;
}

int main()
{
    DriverPackageIdentity packageP { L"old-store-P", std::wstring(64, L'a'), std::wstring(64, L'b') };
    DriverPackageIdentity packageQ { L"reused-store-Q", std::wstring(64, L'c'), std::wstring(64, L'd') };
    DriverMetadata ownerA;
    ownerA.component = { true, L"A" }; ownerA.createdByComponent = { true, L"A" };
    ownerA.strongname = { true, packageP.storeInf }; ownerA.oem = { true, L"oem19.inf" };
    ownerA.infHash = { true, packageP.infHash }; ownerA.catalogHash = { true, packageP.catalogHash };
    DriverMetadata consumerB = ownerA;
    consumerB.component.value = L"B"; consumerB.createdByComponent = DriverMetadataValue();
    std::map<std::wstring, DriverPublishedPackage> hints;
    std::vector<DriverPublishedPackage> published;
    auto lookup = [&](const std::wstring& hint, DriverPublishedPackage& candidate) {
        auto at = hints.find(hint); if (at == hints.end()) return false; candidate = at->second; return true;
    };
    auto scan = [&](std::vector<DriverPublishedPackage>& candidates) { candidates = published; return true; };
    DriverPublishedPackage resolved;
    auto resolveA = [&]() { return ResolveDriverPackageIdentity(MetadataPackageIdentity(ownerA),
        { ownerA.strongname.value, ownerA.oem.value }, lookup, scan, resolved); };
    // B's forward reinstallation moves P; A's old alias has been reused by a different package Q.
    hints[L"oem19.inf"] = { L"oem19.inf", packageQ };
    auto moved = packageP; moved.storeInf = L"new-store-P";
    published = { { L"oem42.inf", moved }, { L"oem19.inf", packageQ } };
    assert(resolveA() == DriverResolution::found && resolved.published == L"oem42.inf");
    // B's rollback can move P again; A is unchanged yet its subsequent uninstall still resolves P.
    moved.storeInf = L"rollback-store-P";
    published = { { L"oem57.inf", moved }, { L"oem19.inf", packageQ } };
    assert(resolveA() == DriverResolution::found && resolved.published == L"oem57.inf");
    assert(ownerA.oem.value == L"oem19.inf" && ownerA.createdByComponent.value == L"A");
    assert(!consumerB.createdByComponent.present);
    hints[packageP.storeInf] = { L"oem57.inf", moved };
    assert(resolveA() == DriverResolution::found); // Valid verified hint wins over reused wrong alias.
    hints.clear(); published.push_back({ L"oem58.inf", moved });
    assert(resolveA() == DriverResolution::ambiguous);
    published.clear(); assert(resolveA() == DriverResolution::missing);
    ownerA.infHash = DriverMetadataValue();
    assert(resolveA() == DriverResolution::invalidIdentity); // Unknown old metadata is not backfilled.

    // Production adapter/retained-reference branch: failures must not dispatch an unshared/removal continuation.
    bool known = true, removalDispatched = false;
    auto unshared = [&]() { removalDispatched = true; };
    auto accessDenied = [](const wchar_t*, std::wstring&) -> std::uint32_t { return 5; };
    auto status = CheckRetainedDriverMetadataHash(packageP, accessDenied, known, unshared);
    assert(status == 5 && !known && !removalDispatched);
    auto missing = [](const wchar_t*, std::wstring&) -> std::uint32_t { return 2; };
    status = CheckRetainedDriverMetadataHash(packageP, missing, known, unshared);
    assert(status == 0 && !known && removalDispatched); // Intentional unhashed UNKNOWN, not creator inference.
    removalDispatched = false;
    auto samePackage = [&](const wchar_t* name, std::wstring& value) -> std::uint32_t {
        value = std::wstring(name) == L"infHash" ? packageP.infHash : packageP.catalogHash; return 0;
    };
    status = CheckRetainedDriverMetadataHash(packageP, samePackage, known, unshared);
    assert(status == 0 && known && !removalDispatched); // Retained matching client still protects P.
    auto wrongType = [](const wchar_t*, std::wstring&) -> std::uint32_t { return 1630; };
    status = CheckRetainedDriverMetadataHash(packageP, wrongType, known, unshared);
    assert(status == 1630 && !known && !removalDispatched);
    auto ioFailure = [](const wchar_t*, std::wstring&) -> std::uint32_t { return 1117; };
    status = CheckRetainedDriverMetadataHash(packageP, ioFailure, known, unshared);
    assert(status == 1117 && !known && !removalDispatched);
    auto invalidData = [](const wchar_t*, std::wstring& value) -> std::uint32_t { value = L"invalid"; return 0; };
    status = CheckRetainedDriverMetadataHash(packageP, invalidData, known, unshared);
    assert(status == 13 && !known && !removalDispatched);
    auto missingThenDenied = [](const wchar_t* name, std::wstring&) -> std::uint32_t {
        return std::wstring(name) == L"infHash" ? 2 : 5;
    };
    status = CheckRetainedDriverMetadataHash(packageP, missingThenDenied, known, unshared);
    assert(status == 5 && !known && !removalDispatched); // Missing first value cannot hide second read failure.

    DriverPlan plan;
    plan.key = L"test-key"; plan.installing = true;
    plan.entries.push_back({ L"source.inf", L"component-A", 0, false });
    DriverUndoRecord record;
    record.sourceInf = plan.entries[0].source; record.component = plan.entries[0].component;
    record.metadataKey = DriverMetadataKey(record.component); record.sourcePackage = packageP;
    DriverBinding binding; binding.instance = L"PCI\\captured-A"; record.bindings.push_back(binding);
    std::wstring journal;
    Frame(journal, { DriverJournalSchema, plan.key, L"1", L"1" });
    std::vector<std::wstring> snapshot;
    EncodeDriverSnapshot(record, snapshot); snapshot.insert(snapshot.begin(), L"snapshot");
    Frame(journal, snapshot);
    Frame(journal, { L"stage", L"0", L"1", L"oem42.inf", packageP.storeInf, packageP.infHash, packageP.catalogHash });
    Frame(journal, { L"bind", L"0", L"0" });
    Frame(journal, { L"metadata", L"0" });
    auto good = Bytes(journal);
    auto damaged = good; damaged.push_back(0x80); // Ordinary failed append leaves an odd byte after A.
    unsigned offset = 0, reads = 0;
    auto prefix = ReadDriverScriptPrefix(static_cast<unsigned>(damaged.size()),
        [&](unsigned char* buffer, unsigned wanted, unsigned& got) {
            ++reads; got = (std::min)(wanted, 3u); // Include short, odd-sized successful reads.
            std::copy(damaged.begin()+offset, damaged.begin()+offset+got, buffer); offset += got; return true;
        });
    assert(prefix.status == DriverPrefixStatus::corrupt && reads <= damaged.size());
    std::vector<DriverUndoRecord> records;
    assert(ParseDriverJournal(plan, prefix.text, records));
    unsigned dispatched = 0;
    auto restore = [&](DriverUndoRecord& earlier) -> std::int32_t {
        assert(earlier.stageKnown && earlier.bindings[0].attempted && earlier.metadataAttempted);
        ++dispatched; return 0;
    };
    bool journalDeleted = false;
    auto cleanup = [&]() { journalDeleted = true; };
    std::int32_t originalCorruption = -13;
    auto result = ReplayDriverInverseRecords(records, originalCorruption, restore, cleanup);
    assert(dispatched == 1 && result == originalCorruption && !journalDeleted); // Native branch retains journal.
    offset = 0;
    auto readFailure = ReadDriverScriptPrefix(static_cast<unsigned>(good.size()+8),
        [&](unsigned char* buffer, unsigned, unsigned& got) {
            got = static_cast<unsigned>(good.size()); std::copy(good.begin(), good.end(), buffer); return false;
        });
    assert(readFailure.status == DriverPrefixStatus::readError);
    records.clear(); assert(ParseDriverJournal(plan, readFailure.text, records));
    result = ReplayDriverInverseRecords(records, -29, restore, cleanup);
    assert(dispatched == 2 && result == -29 && !journalDeleted);
    records.clear();
    assert(!ParseDriverJournal(plan, journal + wchar_t(128) + L"9" + wchar_t(128) + L"partial", records));
    assert(ReplayDriverInverseRecords(records, originalCorruption, restore, cleanup) == originalCorruption && dispatched == 3 && !journalDeleted);
}
