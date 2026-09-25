import UIKit
import Contacts
import ContactsUI
import ReminderCore

/// Presents the system contact picker. The picker runs out of process, so it
/// needs no Contacts permission and only returns the people the user picks.
@MainActor
final class ContactImporter: NSObject, CNContactPickerDelegate {
    struct PickedContact {
        let name: String
        let handle: String
    }

    static let shared = ContactImporter()

    private var completion: (([PickedContact]) -> Void)?

    /// Presented from UIKit directly: wrapping CNContactPickerViewController in a
    /// SwiftUI sheet leaves an empty sheet behind when it dismisses itself.
    func present(completion: @escaping ([PickedContact]) -> Void) {
        guard let presenter = Self.topViewController() else { return }
        self.completion = completion
        let picker = CNContactPickerViewController()
        picker.delegate = self
        picker.displayedPropertyKeys = [CNContactPhoneNumbersKey, CNContactEmailAddressesKey]
        picker.predicateForEnablingContact = NSPredicate(format: "phoneNumbers.@count > 0 OR emailAddresses.@count > 0")
        presenter.present(picker, animated: true)
    }

    func contactPicker(_ picker: CNContactPickerViewController, didSelect contacts: [CNContact]) {
        let picked = contacts.compactMap(Self.pick)
        completion?(picked)
        completion = nil
    }

    func contactPickerDidCancel(_ picker: CNContactPickerViewController) {
        completion = nil
    }

    /// Prefers an iPhone or mobile number, then any number, then an email.
    private static func pick(_ contact: CNContact) -> PickedContact? {
        let name = displayName(of: contact)
        if contact.isKeyAvailable(CNContactPhoneNumbersKey) {
            let preferredLabels = [CNLabelPhoneNumberiPhone, CNLabelPhoneNumberMobile]
            let phones = contact.phoneNumbers
            let preferred = phones.first { preferredLabels.contains($0.label ?? "") } ?? phones.first
            if let number = preferred?.value.stringValue {
                return PickedContact(name: name, handle: number)
            }
        }
        if contact.isKeyAvailable(CNContactEmailAddressesKey),
           let email = contact.emailAddresses.first?.value {
            return PickedContact(name: name, handle: email as String)
        }
        return nil
    }

    private static func displayName(of contact: CNContact) -> String {
        var parts: [String] = []
        if contact.isKeyAvailable(CNContactGivenNameKey), !contact.givenName.isEmpty {
            parts.append(contact.givenName)
        }
        if contact.isKeyAvailable(CNContactFamilyNameKey), !contact.familyName.isEmpty {
            parts.append(contact.familyName)
        }
        if parts.isEmpty, contact.isKeyAvailable(CNContactOrganizationNameKey) {
            return contact.organizationName
        }
        return parts.joined(separator: " ")
    }

    private static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes.flatMap(\.windows).first { $0.isKeyWindow } ?? scenes.first?.windows.first
        var top = window?.rootViewController
        while let presented = top?.presentedViewController {
            top = presented
        }
        return top
    }
}
