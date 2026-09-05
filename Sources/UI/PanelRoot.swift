import SwiftUI

/// A panel page. Navigation is only two levels deep: timeline → slot → wallpaper picker.
/// Settings and location sit alongside slots, one level forward from the timeline.
enum Page: Equatable {
    case timeline
    case slot(UUID)
    case picker(UUID)
    case settings
    case place
}

/// The menu bar panel root.
///
/// A fixed 360 × 470 canvas with three pages sliding horizontally, like system panels
/// such as Control Center or Wi-Fi: no new windows and no resizing during navigation.
struct PanelRoot: View {
    @Environment(AppModel.self) private var model
    @State private var page: Page = .timeline
    /// Location can open from the timeline or settings; return to the originating page.
    @State private var placeBack: Page = .timeline

    var body: some View {
        ZStack {
            switch page {
            case .timeline:
                TimelinePage(open: navigate)
                    .transition(pageTransition)
            case .slot(let id):
                SlotPage(slotID: id, open: navigate)
                    .transition(pageTransition)
            case .picker(let id):
                WallpaperPicker(slotID: id, open: navigate)
                    .transition(pageTransition)
            case .settings:
                SettingsPage(open: navigate)
                    .transition(pageTransition)
            case .place:
                PlacePage(open: navigate, backPage: placeBack)
                    .transition(pageTransition)
            }
        }
        // Rebuild this subtree when the language changes. Put `.id` on the pages, not `PanelRoot`,
        // so `page` survives: changing the language in settings leaves the user in settings.
        .id(model.languageGeneration)
        // Lock width; each page owns its height (timeline fits its slots, picker fills the panel).
        .frame(width: Panel.width)
        .animation(Panel.pageAnimation, value: page)
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
        if target == .place { placeBack = page == .place ? placeBack : page }
        if target == .timeline { model.endEditing() }
        page = target
    }

    /// Fade out, then fade in: the insertion waits for the removal to finish so pages never overlap.
    /// See `Panel.pageAnimation` for why this is not a slide or crossfade.
    private var pageTransition: AnyTransition {
        let fade = Panel.pageFadeDuration
        return .asymmetric(
            insertion: .opacity.animation(.easeIn(duration: fade).delay(fade)),
            removal: .opacity.animation(.easeOut(duration: fade)))
    }
}
