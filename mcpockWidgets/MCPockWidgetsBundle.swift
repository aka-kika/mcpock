import WidgetKit
import SwiftUI

/// mcpock's three desktop widgets (round 8): overall status (small), the
/// problems list (medium) and per-agent health (medium). All three read the
/// same App Group snapshot the app writes; none of them probe anything
/// themselves — a widget extension is sandboxed and read-only by design here.
@main
struct MCPockWidgetsBundle: WidgetBundle {
    var body: some Widget {
        MCPockStatusWidget()
        MCPockProblemsWidget()
        MCPockAgentsWidget()
    }
}
