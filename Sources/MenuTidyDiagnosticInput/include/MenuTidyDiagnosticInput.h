#ifndef MENU_TIDY_DIAGNOSTIC_INPUT_H
#define MENU_TIDY_DIAGNOSTIC_INPUT_H

#include <stdbool.h>
#include <stdint.h>
#include <CoreGraphics/CGEvent.h>

// CLI diagnostic only. Posts one legacy left-button state with the documented
// updateMouseCursorPosition argument false. This does NOT promise isolation of
// global button state, focus, or event routing. Never used by normal app actions.
int32_t MenuTidyDiagnosticLegacyMouseButton(double x, double y, bool down);

// Explicit private-record CLI diagnostic only. Availability verifies the exact
// arm64 system build and wrapper instructions inspected for this experiment.
// This is not a supported Apple API or a promise of input-state isolation.
bool MenuTidyDiagnosticPrivateRecordAvailable(void);
int32_t MenuTidyDiagnosticPrivateRecordPost(CGEventRef event);

#endif
