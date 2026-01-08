# SwiftDockKit version 3

Version 3 of Docket allows nested stages.  

## Nesting

In the current version, a stage host needs to be a window. In the new version, a stage host is allowed to be docked as a panel. 

## Swipe gesture

The two-finger gesture is still used to switch between stages. The new behavior, however, is that it switches the stage on the lowermost stage host. Only if the lowermost stage host is at the end of its stages. The gesture is translated in a higher-level stage host. This is true both for flicks and for slow drags using two fingers. 
