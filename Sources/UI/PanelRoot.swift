import SwiftUI

/// A panel page. Navigation is only two levels deep: timeline → slot → wallpaper picker.
/// Settings and location sit alongside slots, one level forward from the timeline.
enum Page: Equatable {
    case timeline
    case slot(UUID)
    case picker(UUID)
    case settings
    case place

    var depth: Int {
        switch self {
        case .timeline: return 0
        case .slot:     return 1
        case .settings: return 1
        case .place:    return 1
        case .picker:   return 2
        }
    }
}

/// The menu bar panel root.
///
/// A fixed 360 × 470 canvas with three pages sliding horizontally, like system panels
/// such as Control Center or Wi-Fi: no new windows and no resizing during navigation.
struct PanelRoot: View {
    @Environment(AppModel.self) private var model
    @State private var page: Page = .timeline
    /// Navigation direction determines which side the transition enters from.
    @State private var forward = true
    /// Location can open from the timeline or settings; return to the originating page.
    @State private var placeBack: Page = .timeline

    var body: some View {
        ZStack {
            switch page {
            case .timeline:
                TimelinePage(open: navigate)
                    .transition(slide)
            case .slot(let id):
                SlotPage(slotID: id, open: navigate)
                    .transition(slide)
            case .picker(let id):
                WallpaperPicker(slotID: id, open: navigate)
                    .transition(slide)
            case .settings:
                SettingsPage(open: navigate)
                    .transition(slide)
            case .place:
                PlacePage(open: navigate, backPage: placeBack)
                    .transition(slide)
            }
        }
        // Rebuild this subtree when the language changes. Put `.id` on the pages, not `PanelRoot`,
        // so `page` survives: changing the language in settings leaves the user in settings.
        .id(model.languageGeneration)
        // Lock width; each page owns its height (timeline fits its slots, picker fills the panel).
        .frame(width: Panel.width)
        .animation(Panel.animation, value: page)
        .background(PanelVisibilityObserver { model.setPanelVisible($0) })
        .onAppear {
            // Losing focus closes the panel, including when choosing a local image. Keep unfinished drafts
            // and return to their slot on reopening rather than silently discarding unapplied edits.
            // If external configuration deleted the slot while closed, discard its draft instead of reviving it.
            switch page {
            case .timeline:
                if let draft = model.draft {
                    if model.canContinueEditing(draft.id) {
                        navigate(.slot(draft.id))
                    } else {
                        model.endEditing()
                    }
                }
            case .slot(let id), .picker(let id):
                if !model.canContinueEditing(id) { navigate(.timeline) }
            case .settings, .place:
                break
            }
        }
        .onChange(of: model.schedule.slots.map(\.id)) {
            // Slots can disappear externally (manual schedule.json edits or another process).
            // Return to the timeline rather than showing an empty page for a missing slot.
            // New drafts are not in the configuration yet; `editing` recognizes them so they remain open.
            if case .slot(let id) = page, !model.canContinueEditing(id) { navigate(.timeline) }
            if case .picker(let id) = page, !model.canContinueEditing(id) { navigate(.timeline) }
        }
    }

    /// Returning to the timeline ends editing and discards changes that were not applied.
    private func navigate(_ target: Page) {
        if target == .place {
            placeBack = page == .place ? placeBack : page
            forward = true
        } else if page == .place {
            forward = false
        } else {
            forward = target.depth > page.depth
        }
        if target == .timeline { model.endEditing() }
        page = target
    }

    private var slide: AnyTransition {
        .asymmetric(
            insertion: .move(edge: forward ? .trailing : .leading).combined(with: .opacity),
            removal: .move(edge: forward ? .leading : .trailing).combined(with: .opacity))
    }
}
