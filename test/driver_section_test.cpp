#include "../src/DrvInst/DrvInstCA/DriverTransaction.h"
#include <cassert>
#include <cwchar>

int main()
{
    DriverBinding prior;
    prior.section = L"BALLOON_Device.NT";
    // N16 read-only witness: property Ext is absent; Models/detail name is undecorated.
    auto equal = [](const wchar_t* a, const wchar_t* b) { return std::wcscmp(a, b) == 0; };
    assert(!DriverBindingSectionMatches(prior, L"BALLOON_Device", equal));
    assert(DriverBindingSectionMatches(prior, L"BALLOON_Device.NT", equal));
    // No resolved compatible candidate, or a different platform section, cannot authorize selection.
    assert(!DriverBindingSectionMatches(prior, L"", equal));
    assert(!DriverBindingSectionMatches(prior, L"BALLOON_Device.NTarm64", equal));
    prior.section = L"BALLOON_Device";
    prior.sectionExt = L".NT";
    assert(DriverBindingSectionMatches(prior, L"BALLOON_Device.NT", equal));
    prior.sectionExt = L"NT";
    assert(DriverBindingSectionMatches(prior, L"BALLOON_Device.NT", equal));
    prior.sectionExt = L".NTamd64";
    assert(!DriverBindingSectionMatches(prior, L"BALLOON_Device.NT", equal));
}
