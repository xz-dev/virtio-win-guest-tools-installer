// Portable contracts for the real production header, not Windows delivery acceptance.
#include "DriverTransaction.h"
#include <cassert>
#include <iostream>
#ifdef NDEBUG
#error Run contract tests with assertions enabled
#endif
static DriverUndoRecord Snapshot(const wchar_t* component)
{
    DriverUndoRecord r; r.sourceInf=L"fixture.inf"; r.component=component;
    r.metadataKey=DriverMetadataKey(r.component);
    r.sourcePackage={L"fixture-store.inf",std::wstring(64,L'a'),std::wstring(64,L'b')};
    return r;
}
static std::wstring Frame(const std::vector<std::wstring>& fields)
{
    std::wstring s=std::to_wstring(fields.size());
    for(const auto& f:fields){s+=wchar_t(128);s+=f;}
    return s+wchar_t(128)+L"complete"+wchar_t(128);
}
int main()
{
    unsigned checks=0;
    for(const auto& dependencies:std::vector<std::vector<std::wstring>>{{},{L"RpcSs"},{L"RpcSs",L"+Group"}})
    {
        auto r=Snapshot(L"service");DriverServiceConfig service;
        service.name=L"FixtureService";service.imagePath=L"C:\\fixture.sys";service.loadOrderGroup=L"Group";
        service.type=1;service.start=3;service.error=1;service.dependencies=dependencies;r.services.push_back(service);
        std::vector<std::wstring> fields;EncodeDriverSnapshot(r,fields);DriverUndoRecord decoded;
        assert(DecodeDriverSnapshot(fields,decoded));++checks;
        assert(decoded.services.size()==1 && decoded.services[0].dependencies==dependencies);++checks;
        assert(decoded.services[0].imagePath==service.imagePath && decoded.services[0].loadOrderGroup==service.loadOrderGroup && decoded.services[0].type==1 && decoded.services[0].start==3 && decoded.services[0].error==1);++checks;
        auto truncated=fields;truncated.pop_back();assert(!DecodeDriverSnapshot(truncated,decoded));++checks;
        fields.push_back(L"extra");assert(!DecodeDriverSnapshot(fields,decoded));++checks;
    }
    auto identity=Snapshot(L"identity").sourcePackage;
    for(unsigned missing:{1u,2u,3u})
    {
        bool known=true,unshared=false;
        auto read=[&](const wchar_t* name,std::wstring& value)->std::uint32_t{
            bool inf=std::wstring(name)==L"infHash";if(missing&(inf?1u:2u))return 2;
            value=inf?identity.infHash:identity.catalogHash;return 0;};
        assert(CheckRetainedDriverMetadataHash(identity,read,known,[&]{unshared=true;})==0 && !known && !unshared);++checks;
    }
    const auto failure=static_cast<std::int32_t>(0x8007001d),incomplete=static_cast<std::int32_t>(0x8007139f);
    auto r=Snapshot(L"intent-write-fails");unsigned copies=0,deletes=0;
    auto result=StageDriverPackageWithIntent(r,0,
        [&](DriverPackageIdentity&,std::wstring&,bool&)->std::int32_t{++copies;return 0;},
        [&](const std::vector<std::wstring>&)->std::int32_t{return failure;},
        [&](const std::wstring&){++deletes;});
    assert(result==failure && copies==0 && deletes==0 && !r.stageIntent);++checks;
    DriverPlan plan;plan.key=L"fixture-journal";plan.installing=true;std::wstring recordsText;
    auto addSnapshot=[&](const DriverUndoRecord& x){plan.entries.push_back({x.sourceInf,x.component,0,false});std::vector<std::wstring> fields;EncodeDriverSnapshot(x,fields);fields.insert(fields.begin(),L"snapshot");recordsText+=Frame(fields);};
    auto earlier=Snapshot(L"earlier");addSnapshot(earlier);
    recordsText+=Frame({L"stage-intent",L"0"})+Frame({L"stage",L"0",L"1",L"oem41.inf",identity.storeInf,identity.infHash,identity.catalogHash});
    r=Snapshot(L"completion-and-cleanup-fail");addSnapshot(r);copies=deletes=0;
    result=StageDriverPackageWithIntent(r,1,
        [&](DriverPackageIdentity& p,std::wstring& published,bool& created)->std::int32_t{++copies;p=identity;published=L"oem42.inf";created=true;return 0;},
        [&](const std::vector<std::wstring>& e)->std::int32_t{if(e[0]==L"stage-intent"){recordsText+=Frame(e);return 0;}recordsText+=L"7";recordsText+=wchar_t(128);recordsText+=L"stage";return failure;},
        [&](const std::wstring& published)->std::int32_t{assert(published==L"oem42.inf");++deletes;return failure;});
    assert(result==failure && copies==1 && deletes==1 && DriverStageIntentIncomplete(r));++checks;
    std::vector<DriverUndoRecord> records;
    assert(!ParseDriverJournal(plan,Frame({DriverJournalSchema,plan.key,L"1",L"2"})+recordsText,records) && records.size()==2);++checks;
    assert(records[0].stageKnown && DriverStageIntentIncomplete(records[1]));++checks;
    unsigned restored=0,unknownDeletes=0,cleanup=0;
    result=ReplayDriverInverseRecords(records,failure,[&](DriverUndoRecord& x)->std::int32_t{
        if(DriverStageIntentIncomplete(x))return incomplete;
        if(x.stageKnown)++restored;else ++unknownDeletes;return 0;},[&]{++cleanup;});
    assert(result==failure && restored==1 && unknownDeletes==0 && cleanup==0);++checks;
    records={earlier};cleanup=0;
    assert(ReplayDriverInverseRecords(records,0,[](DriverUndoRecord&)->std::int32_t{return 0;},[&]{++cleanup;})==0 && cleanup==1);++checks;
    r=Snapshot(L"no-creation-proof");deletes=0;
    result=StageDriverPackageWithIntent(r,0,
        [&](DriverPackageIdentity&,std::wstring&,bool&)->std::int32_t{return failure;},
        [](const std::vector<std::wstring>&)->std::int32_t{return 0;},[&](const std::wstring&){++deletes;});
    assert(result==failure && deletes==0 && DriverStageIntentIncomplete(r));++checks;
    DriverPlan empty;empty.key=L"empty";empty.installing=true;records.clear();
    assert(!ParseDriverJournal(empty,Frame({L"VirtioDriverTransaction5",empty.key,L"1",L"0"}),records));++checks;
    std::cout<<checks<<" production-header contracts passed; Windows execution is separate\n";
}
