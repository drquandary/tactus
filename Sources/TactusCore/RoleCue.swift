// Tactus · RoleCue.swift
//
// Which pattern each kind of on-screen element plays, so different controls feel different under the pointer
// or when they get keyboard focus. Roles are macOS Accessibility roles ("AXButton", "AXLink"…).

import Foundation

public enum RoleCue {
    /// The pattern name for an element, or nil for elements that shouldn't make a cue (plain text, groups…).
    /// `checked` is the value of a checkbox, radio button or switch, when there is one.
    public static func patternName(role: String, subrole: String?, checked: Bool?) -> String? {
        if subrole == "AXCloseButton" { return "close" }
        switch role {
        case "AXButton", "AXDisclosureTriangle": return "button"
        case "AXLink": return "link"
        case "AXTextField", "AXTextArea", "AXComboBox", "AXSearchField": return "field"
        case "AXCheckBox", "AXRadioButton", "AXSwitch":
            if subrole == "AXTabButton" { return "button" }
            return checked == true ? "toggle-on" : "toggle-off"
        case "AXSlider", "AXIncrementor", "AXStepper": return "slider"
        case "AXMenuItem", "AXMenuBarItem": return "menu"
        case "AXHeading": return "heading"
        case "AXImage": return "image"
        case "AXPopUpButton", "AXMenuButton": return "popup"
        default: return nil
        }
    }

    /// Roles worth stopping at when walking up from the element under the pointer (labels and icons often
    /// sit inside the control they belong to).
    public static func isCueRole(_ role: String) -> Bool {
        patternName(role: role, subrole: nil, checked: nil) != nil
    }
}
