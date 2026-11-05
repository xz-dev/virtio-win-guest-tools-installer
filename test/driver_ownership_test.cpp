#include "../src/DrvInst/DrvInstCA/DriverOwnership.h"
#include <cassert>

int main()
{
    // N06: installed/nonPermanent/sole old owner, omitted by actual selection.
    assert(!LegacyDriverRemovalIsSafe(true, false, false, false));
    // Safe handoff does not depend on private DIFx persistence, even when damaged.
    assert(LegacyDriverRemovalIsSafe(true, false, false, true));
    assert(LegacyDriverRemovalIsSafe(false, false, false, false));
    assert(LegacyDriverRemovalIsSafe(true, false, true, false));
    assert(LegacyDriverRemovalIsSafe(true, true, false, false));
    // Same static GUID without an actual selected successor owner is not enough.
    assert(!LegacyDriverRemovalIsSafe(true, false, false, false));
}
