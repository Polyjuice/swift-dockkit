# SwiftDockKit version 3

Version 3 of Docket allows nested desktops.  

## Nesting

In the current version, a desktop host needs to be a window. In the new version, a desktop host is allowed to be docked as a panel. 

## Swipe gesture

The two-finger gesture is still used to switch between desktops. The new behavior, however, is that it switches the desktop on the lowermost desktop host. Only if the lowermost desktop host is at the end of its desktops. The gesture is translated in a higher-level desktop host. This is true both for flicks and for slow drags using two fingers. 
