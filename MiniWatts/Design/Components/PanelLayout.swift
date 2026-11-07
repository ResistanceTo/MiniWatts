import SwiftUI

/// How a page lays its panels out once the screen is wide enough for two columns.
enum PanelLayout {
    /// Panels of different heights, a handful of them: balanced into two columns by
    /// `PanelColumns`, in reading order.
    case panels
    /// A long run of similar rows — History's sessions. A lazy two-column grid, since
    /// balancing would have to build and measure all sixty of them.
    case list
}

/// The width from which a page uses two columns of panels.
///
/// 960 pt puts every iPad in landscape and the 13-inch in portrait (1032 pt) on two
/// columns of 470 pt or more — about the width of an iPhone Pro Max, which is what
/// every panel was designed at. An 11-inch in portrait (834 pt), Split View and Slide
/// Over stay on one column, capped at 760 pt as before.
let widePanelsMinimumWidth: CGFloat = 960

/// A page's scrolling column of panels: one column on a phone, two on a wide iPad.
///
/// Every page's content goes through here — `PageScaffold` for the five tabs, and the
/// session detail pushed from History, which used to stretch edge to edge on an iPad
/// because it had no cap at all.
///
/// The width is read from a `GeometryReader` outside the scroll view, never from the
/// scroll view itself. The column used to be pinned with `containerRelativeFrame`,
/// whose container is the scroll view — and a scroll view takes its width across the
/// scroll axis from its content. With a fixed cap below every screen width that loop
/// never showed. With a two-column cap it locked: turned from landscape to portrait, the
/// content kept the scroll view 1,210 pt wide, the scroll view kept the content at
/// 1,210, and the page overflowed both edges of an 834 pt screen. The reader takes what
/// its parent offers and nothing else, and it has the width on the first layout pass,
/// so a page that `TabPage` has just rebuilt starts in the right number of columns.
struct PanelScroll<Content: View>: View {
    var layout: PanelLayout = .panels
    @ViewBuilder var content: () -> Content

    var body: some View {
        GeometryReader { proxy in
            let isWide = proxy.size.width >= widePanelsMinimumWidth
            ScrollView {
                Group {
                    if isWide {
                        switch layout {
                        case .panels:
                            PanelColumns(spacing: 14) {
                                PageContent(content: content)
                            }
                        case .list:
                            LazyVGrid(columns: [GridItem(.flexible(), spacing: 14, alignment: .top),
                                                GridItem(.flexible(), spacing: 14, alignment: .top)],
                                      spacing: 14) {
                                PageContent(content: content)
                            }
                        }
                    } else {
                        // Lazy, not a plain `VStack`. History puts up to sixty session
                        // panels in here, each with its own sparkline, and an eager stack
                        // builds and measures every one of them — while charging, once a
                        // second, because the page reads the live session.
                        LazyVStack(spacing: 14) {
                            PageContent(content: content)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .padding(.bottom, 24)
                // Pinned to a fixed width so nothing inside can widen the scroll
                // content. A paragraph inside an HStack reports an enormous ideal
                // width — the text unwrapped onto one line — and
                // `.frame(maxWidth: .infinity)` only expands, it does not clamp, so
                // that width propagates up and the page starts scrolling sideways.
                //
                // Capped for an iPad — 760 pt for one column, 1,280 for two — and the
                // cap has to be part of this same frame: the pin is a fixed width, so a
                // `frame(maxWidth:)` after it cannot narrow it.
                .frame(width: min(proxy.size.width, isWide ? 1280 : 760))
                .frame(maxWidth: .infinity)
            }
        }
    }
}

/// Calls a page's content closure, so that the monitor reads inside it are this
/// view's dependencies and not the scaffold's. A custom view's body is flattened
/// into the enclosing container, so the stack stays lazy panel by panel and
/// `PanelColumns` sees each panel as a subview of its own.
private struct PageContent<Content: View>: View {
    let content: () -> Content

    var body: some View {
        content()
    }
}

/// Two columns of panels, filled in reading order: the first panels go down the
/// left, the rest down the right, split where the two come out closest in height.
///
/// Not a masonry grid, which puts each panel under whichever column is shorter so
/// far. Panel heights change with what they show — a note appears, a list grows by
/// a sensor — and they change every tick; with that rule panels hopped from column
/// to column while the page was being read. Here only the panel at the split can
/// move, and only when moving it gains more than `stickiness`.
///
/// One panel on its own takes the full width: a lone "Not connected" in the left
/// half of a wide page looked like the right half had failed to load.
nonisolated struct PanelColumns: Layout {
    var spacing: CGFloat = 14
    var stickiness: CGFloat = 80

    struct Cache {
        var split: Int?
    }

    func makeCache(subviews: Subviews) -> Cache { Cache() }

    /// Keeps the split across updates. The default rebuilds the cache from scratch
    /// whenever a subview changes, which is every tick, and the split would be chosen
    /// afresh each time — exactly the hopping this layout exists to avoid.
    func updateCache(_ cache: inout Cache, subviews: Subviews) {}

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        guard let width = proposal.width, width.isFinite else {
            // An ideal-size query. Answer with one column and leave the split alone.
            let heights = subviews.map { $0.sizeThatFits(.unspecified).height }
            let width = subviews.map { $0.sizeThatFits(.unspecified).width }.max() ?? 0
            return CGSize(width: width, height: stacked(heights[...]))
        }
        return CGSize(width: width, height: arrange(width: width, subviews: subviews, cache: &cache).height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        let plan = arrange(width: bounds.width, subviews: subviews, cache: &cache)
        var y = [bounds.minY, bounds.minY]
        for (index, subview) in subviews.enumerated() {
            let column = index < plan.split ? 0 : 1
            let x = column == 0 ? bounds.minX : bounds.minX + plan.columnWidth + spacing
            subview.place(at: CGPoint(x: x, y: y[column]),
                          anchor: .topLeading,
                          proposal: ProposedViewSize(width: plan.columnWidth, height: plan.heights[index]))
            if plan.heights[index] > 0 { y[column] += plan.heights[index] + spacing }
        }
    }

    private struct Plan {
        /// Subviews before this index are in the left column.
        var split: Int
        var columnWidth: CGFloat
        var heights: [CGFloat]
        var height: CGFloat
    }

    private func arrange(width: CGFloat, subviews: Subviews, cache: inout Cache) -> Plan {
        let count = subviews.count
        guard count > 1 else {
            let heights = subviews.map { $0.sizeThatFits(ProposedViewSize(width: width, height: nil)).height }
            return Plan(split: count, columnWidth: width, heights: heights, height: stacked(heights[...]))
        }
        let columnWidth = max((width - spacing) / 2, 0)
        let heights = subviews.map { $0.sizeThatFits(ProposedViewSize(width: columnWidth, height: nil)).height }
        func tallest(_ split: Int) -> CGFloat {
            max(stacked(heights[..<split]), stacked(heights[split...]))
        }
        let best = (1..<count).min { tallest($0) < tallest($1) } ?? 1
        var split = best
        if let previous = cache.split, (1..<count).contains(previous),
           tallest(previous) <= tallest(best) + stickiness {
            split = previous
        }
        cache.split = split
        return Plan(split: split, columnWidth: columnWidth, heights: heights, height: tallest(split))
    }

    /// The height of a column: its panels plus the spacing between them. A subview
    /// with no height — a conditional that drew nothing — takes no spacing either.
    private func stacked(_ heights: ArraySlice<CGFloat>) -> CGFloat {
        let drawn = heights.filter { $0 > 0 }
        guard !drawn.isEmpty else { return 0 }
        return drawn.reduce(0, +) + spacing * CGFloat(drawn.count - 1)
    }
}
