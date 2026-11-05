#pragma once

// Only a retained machine owner makes legacy last-owner removal unnecessary.
inline bool LegacyDriverRemovalIsSafe(bool installed, bool permanent,
    bool retainedMachineOwner, bool successorRequestsSameComponent)
{
    return !installed || permanent || retainedMachineOwner || successorRequestsSameComponent;
}
