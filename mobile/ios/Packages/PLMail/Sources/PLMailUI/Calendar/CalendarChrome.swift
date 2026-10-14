#if os(iOS)

public import PLMailCore

import JMAPKit

import SwiftUI

/// The calendar's own bar, drawn inside its card.
///
/// **Not a `.toolbar`.** The design puts the calendar in the same card the mail
/// list sits in, with one bar across the top of it — and a SwiftUI toolbar
/// cannot be that, because it belongs to the navigation bar above the card and
/// scatters its items into floating capsules across the window. What is here is
/// the same set of controls the toolbar carried, in the order and the shapes
/// the design draws them.
///
/// Compact widths never see this: a phone gets the navigation bar, which is
/// what a phone should have, and the segmented control folds back into a menu
/// there.
struct CalendarBar: View {
    let heading: String
    @Binding var mode: CalendarViewMode
    let canPage: Bool
    let onStep: (Int) -> Void
    let onToday: () -> Void
    /// Adds an event. Absent where `myRights` accepts a new item on no
    /// calendar at all — a control that cannot work is not offered here,
    /// because the compact toolbar already carries the disabled one that
    /// explains why.
    var onCreate: (() -> Void)?
    @Binding var isSearching: Bool
    /// Leaves the calendar. Absent when there is nothing to go back to.
    var onCollapse: (() -> Void)?

    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var colorScheme

    private var palette: ThemePalette { theme.palette(for: colorScheme) }

    var body: some View {
        HStack(spacing: 10) {
            Text(verbatim: heading)
                .font(.system(size: 16, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .accessibilityAddTraits(.isHeader)

            if canPage {
                HStack(spacing: 2) {
                    step(-1, symbol: "chevron.left", label: .ui("Previous"))
                    step(1, symbol: "chevron.right", label: .ui("Next"))
                }
            }

            Button(action: onToday) {
                Text(.ui("Today"))
                    .font(.system(size: 13, weight: .medium))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(palette.accentSoft.color, in: .capsule)
            }
            .buttonStyle(.plain)
            .foregroundStyle(ThemeAccent())

            Spacer(minLength: 8)

            // Never squeezed: without this the row compresses five words into
            // five columns of stacked letters rather than dropping the label
            // beside it, which is exactly what a segmented control must not do.
            ModeSwitch(mode: $mode)
                .fixedSize()

            Button {
                isSearching.toggle()
            } label: {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 14))
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.plain)
            .foregroundStyle(
                isSearching ? AnyShapeStyle(ThemeAccent()) : AnyShapeStyle(palette.inkSoft.color)
            )
            .accessibilityLabel(Text(.ui("Search these dates")))
            .accessibilityAddTraits(isSearching ? [.isButton, .isSelected] : .isButton)

            if let onCreate {
                Button(action: onCreate) {
                    Image(systemName: "plus")
                        .font(.system(size: 15))
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.plain)
                .foregroundStyle(palette.inkSoft.color)
                .accessibilityLabel(Text(.ui("New event")))
            }

            if let onCollapse {
                Button(action: onCollapse) {
                    Image(systemName: "arrow.down.right.and.arrow.up.left")
                        .font(.system(size: 13))
                        .frame(width: 40, height: 40)
                }
                .buttonStyle(.plain)
                .foregroundStyle(palette.inkSoft.color)
                .accessibilityLabel(Text(.ui("Back to mail")))
            }
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 52)
        .background(palette.sunken.color)
        .overlay(alignment: .bottom) { Divider() }
    }

    private func step(
        _ direction: Int, symbol: String, label: LocalizedStringResource
    )
        -> some View
    {
        Button {
            onStep(direction)
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .frame(width: 36, height: 36)
        }
        .buttonStyle(.plain)
        .foregroundStyle(palette.inkSoft.color)
        .accessibilityLabel(Text(label))
    }
}

/// Day · Week · Month · Agenda · Year, as the design draws it.
///
/// Hand-built rather than `.pickerStyle(.segmented)`: the system control paints
/// its own materials and cannot be given the design's sunken track and raised
/// selected tile, and this app's whole point is that the user's theme reaches
/// every surface. It keeps what the system control gives for free —
/// `.isSelected` on the chosen item, one accessibility element per choice, and
/// a real button under each — because losing those would be the wrong trade.
struct ModeSwitch: View {
    @Binding var mode: CalendarViewMode

    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var tile

    private var palette: ThemePalette { theme.palette(for: colorScheme) }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(CalendarViewMode.allCases, id: \.self) { choice in
                Button {
                    mode = choice
                } label: {
                    Text(CalendarModeName.text(choice))
                        .font(.system(size: 13, weight: mode == choice ? .medium : .regular))
                        .foregroundStyle(
                            mode == choice
                                ? AnyShapeStyle(palette.ink.color)
                                : AnyShapeStyle(palette.inkFaint.color)
                        )
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, 11)
                        .padding(.vertical, 6)
                        .background {
                            if mode == choice {
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(palette.surface.color)
                                    .shadow(color: PanelStyle.paneShadow, radius: 1, y: 1)
                                    .matchedGeometryEffect(id: "tile", in: tile)
                            }
                        }
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(mode == choice ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(2)
        .background(palette.sunken.color, in: .rect(cornerRadius: 9, style: .continuous))
        .animation(Motion.fast(theme.motion, reduced: reduceMotion), value: mode)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(.ui("View")))
    }
}

/// The week the anchor sits in, as seven tappable days.
///
/// The design's answer to the one thing a day grid cannot say: *what else is
/// this week*. Today is a filled circle, the anchor is what the grid is
/// showing, and a day carrying anything gets a dot — three different claims,
/// so three different marks rather than three shades of one.
struct WeekStrip: View {
    let anchor: CalendarDay
    let clusters: [EventCluster]
    @Binding var selection: CalendarDay

    @Environment(\.calendar) private var calendar
    @Environment(\.locale) private var locale
    @Environment(\.timeZone) private var timeZone
    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var colorScheme

    private var palette: ThemePalette { theme.palette(for: colorScheme) }

    private var days: [CalendarDay] {
        let start = anchor.startOfWeek(using: calendar)

        return (0..<7).map { start.adding(days: $0) }
    }

    private var today: CalendarDay { CalendarDay(.now, in: timeZone) }

    /// Which days have something on them, computed once for the row rather
    /// than once per cell — seven scans of the same array is seven times the
    /// work for one dot.
    private var busy: Set<CalendarDay> {
        Set(clusters.map { CalendarDay($0.representative.start) })
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(days, id: \.self) { day in
                Button {
                    selection = day
                } label: {
                    cell(day)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(
                    Text(
                        verbatim: CalendarHeading.day(
                            day, template: "EEEEdMMMM", locale: locale, timeZone: timeZone))
                )
                .accessibilityAddTraits(day == selection ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) { Divider() }
    }

    private func cell(_ day: CalendarDay) -> some View {
        VStack(spacing: 3) {
            Text(
                verbatim: CalendarHeading.day(
                    day, template: "EEEEE", locale: locale, timeZone: timeZone)
            )
            .font(.system(size: 11))
            .foregroundStyle(
                day == today ? AnyShapeStyle(ThemeAccent()) : AnyShapeStyle(palette.inkFaint.color))

            Text(verbatim: "\(day.day)")
                .font(.system(size: 16, weight: day == today ? .semibold : .medium))
                .foregroundStyle(
                    day == today
                        ? AnyShapeStyle(palette.accentInk.color)
                        : AnyShapeStyle(palette.inkSoft.color)
                )
                .frame(width: 32, height: 32)
                .background {
                    if day == today {
                        Circle().fill(ThemeAccent())
                    } else if day == selection {
                        Circle().fill(palette.accentSoft.color)
                    }
                }

            Circle()
                .fill(
                    busy.contains(day) ? AnyShapeStyle(ThemeAccent()) : AnyShapeStyle(Color.clear)
                )
                .frame(width: 4, height: 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
        .contentShape(.rect)
    }
}

/// The calendar's search field, below the bar rather than inside it.
///
/// Beneath, so that turning search on does not evict the heading, the week and
/// the mode switch from a row that had exactly enough room for them — a bar
/// that rearranges itself under the cursor is a bar people stop aiming at.
struct CalendarSearchField: View {
    @Binding var text: String
    let onClose: () -> Void

    @FocusState private var isFocused: Bool

    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var colorScheme

    private var palette: ThemePalette { theme.palette(for: colorScheme) }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13))
                .foregroundStyle(palette.inkFaint.color)

            TextField(text: $text) {
                Text(.ui("Search these dates"))
            }
            .textFieldStyle(.plain)
            .focused($isFocused)
            .submitLabel(.search)

            if text.isEmpty == false {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(palette.inkFaint.color)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(.ui("Clear")))
            }

            Button(action: onClose) {
                Text(.ui("Cancel"))
                    .font(.system(size: 13))
            }
            .buttonStyle(.plain)
            .foregroundStyle(ThemeAccent())
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) { Divider() }
        .onAppear { isFocused = true }
    }
}

#endif
