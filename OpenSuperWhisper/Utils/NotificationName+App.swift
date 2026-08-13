import Foundation

extension Notification.Name {
    static let appPreferencesLanguageChanged = Notification.Name("AppPreferencesLanguageChanged")
    static let hotkeySettingsChanged = Notification.Name("HotkeySettingsChanged")
    static let indicatorWindowDidHide = Notification.Name("IndicatorWindowDidHide")
    static let indicatorWindowWillShow = Notification.Name("IndicatorWindowWillShow")
    static let openSettings = Notification.Name("OpenSettings")

    /// The engine the user wants has changed, from somewhere other than the
    /// control the reader is looking at.
    ///
    /// Posted by `EngineSelectionCommand`, which is every user-initiated engine
    /// change. It exists because the engine shortcut can be pressed while the
    /// Settings pane is open, and a picker still showing the previous engine is a
    /// second answer to a question the app is supposed to have only one answer to.
    static let selectedEngineChanged = Notification.Name("SelectedEngineChanged")
}
