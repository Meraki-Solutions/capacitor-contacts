import Foundation
import Capacitor
import Contacts
import ContactsUI


enum CallingMethod {
    case GetContact
    case GetContacts
    case CreateContact
    case DeleteContact
    case PickContact
}

@objc(ContactsPlugin)
public class ContactsPlugin: CAPPlugin, CNContactPickerDelegate {
  private let implementation = Contacts()
  
  private var callingMethod: CallingMethod?

  private var pickContactCallbackId: String?
  
  @objc override public func checkPermissions(_ call: CAPPluginCall) {
    let permissionState: String
    
    switch CNContactStore.authorizationStatus(for: .contacts) {
    case .notDetermined:
      permissionState = "prompt"
    case .restricted, .denied:
      permissionState = "denied"
    case .authorized, .limited:
      permissionState = "granted_limited"
    @unknown default:
      permissionState = "prompt"
    }
    
    call.resolve([
      "contacts": permissionState
    ])
  }
  
  @objc override public func requestPermissions(_ call: CAPPluginCall) {
    CNContactStore().requestAccess(for: .contacts) { [weak self] _, _  in
      self?.checkPermissions(call)
    }
  }
  
  private func requestContactsPermission(_ call: CAPPluginCall, _ callingMethod: CallingMethod) {
    self.callingMethod = callingMethod
    if isContactsPermissionGranted() {
      permissionCallback(call)
    } else {
      CNContactStore().requestAccess(for: .contacts) { [weak self] _, _  in
        self?.permissionCallback(call)
      }
    }
  }
  
  private func isContactsPermissionGranted() -> Bool {
    switch CNContactStore.authorizationStatus(for: .contacts) {
    case .notDetermined, .restricted, .denied:
      return false
    case .authorized, .limited:
      return true
    @unknown default:
      return false
    }
  }
  
  private func permissionCallback(_ call: CAPPluginCall) {
    let method = self.callingMethod

    self.callingMethod = nil
    
    if !isContactsPermissionGranted() {
      call.reject("Permission is required to access contacts.")
      return
    }
    
    switch method {
    case .GetContact:
      getContact(call)
    case .GetContacts:
      getContacts(call)
    case .CreateContact:
      createContact(call)
    case .DeleteContact:
      deleteContact(call)
    case .PickContact:
      pickContact(call)
    default:
      break
    }
  }
  
  @objc func getContact(_ call: CAPPluginCall) {
    if !isContactsPermissionGranted() {
      requestContactsPermission(call, CallingMethod.GetContact)
    } else {
      let contactId = call.getString("contactId")
      guard let contactId = contactId else {
        call.reject("Parameter `contactId` not provided.")
        return
      }
      
      let projectionInput = GetContactsProjectionInput(call.getObject("projection") ?? JSObject())

      let contact = implementation.getContact(contactId, projectionInput)
      
      guard let contact = contact else {
        call.reject("Contact not found.")
        return
      }
      
      call.resolve([
        "contact": contact.getJSObject()
      ])
    }
  }
  
  @objc func getContacts(_ call: CAPPluginCall) {
    if !isContactsPermissionGranted() {
      requestContactsPermission(call, CallingMethod.GetContacts)
    } else {
      let projectionInput = GetContactsProjectionInput(call.getObject("projection") ?? JSObject())
      
      let contacts = implementation.getContacts(projectionInput)

      var contactsJSArray: JSArray = JSArray()
      
      for contact in contacts {
        contactsJSArray.append(contact.getJSObject())
      }
      
      call.resolve([
        "contacts": contactsJSArray
      ])
    }
  }
  
  @objc func createContact(_ call: CAPPluginCall) {
    if !isContactsPermissionGranted() {
      requestContactsPermission(call, CallingMethod.CreateContact)
    } else {
      let contactInput = CreateContactInput.init(call.getObject("contact", JSObject()))
      let contactId = implementation.createContact(contactInput)
      
      guard let contactId = contactId else {
        call.reject("Something went wrong.")
        return
      }
      
      call.resolve([
        "contactId": contactId
      ])
    }
  }
  
  @objc func deleteContact(_ call: CAPPluginCall) {
    if !isContactsPermissionGranted() {
      requestContactsPermission(call, CallingMethod.DeleteContact)
    } else {
      let contactId = call.getString("contactId")
      guard let contactId = contactId else {
        call.reject("Parameter `contactId` not provided.")
        return
      }
      
      if !implementation.deleteContact(contactId) {
        call.reject("Something went wrong.")
        return
      }
      
      call.resolve()
    }
  }
  
  @objc func pickContact(_ call: CAPPluginCall) {
      // Verifica se a permissão de contatos foi concedida
      if !isContactsPermissionGranted() {
          requestContactsPermission(call, .PickContact)
          return
      }
      // Obtém o status atual de autorização
      let status = CNContactStore.authorizationStatus(for: .contacts)
      // Verifica se o dispositivo está no iOS 18.0 ou superior e se o acesso é limitado
      if #available(iOS 18.0, *), status == .limited {
          // Carrega os contatos limitados
          let projectionInput = GetContactsProjectionInput(call.getObject("projection") ?? JSObject())
          let limitedContacts = implementation.getContacts(projectionInput)

          DispatchQueue.main.async {
              let customPicker = LimitedContactPickerViewController()
              customPicker.contacts = limitedContacts
              customPicker.selectionHandler = { selectedContact in
                  call.resolve(["contact": selectedContact.getJSObject()])
                  self.bridge?.releaseCall(call)
              }
              self.bridge?.viewController?.present(customPicker, animated: true, completion: nil)
          }
      } else if status == .authorized {
          // Se o acesso for completo, usa o picker nativo
          DispatchQueue.main.async {
                // Save the call and its callback id
              self.bridge?.saveCall(call)
              self.pickContactCallbackId = call.callbackId

                // Initialize the contact picker
              let contactPicker = CNContactPickerViewController()
                // Mark current class as the delegate class,
                // this will make the callback `contactPicker` actually work.
              contactPicker.delegate = self
                // Present (open) the native contact picker.
                self.bridge?.viewController?.present(contactPicker, animated: true)
          }
      } else {
          // Caso o acesso seja negado ou restrito
          call.reject("Access to contacts is denied or restricted.")
          self.bridge?.releaseCall(call)
      }
  }
 

  // Métodos de delegate para o CNContactPickerViewController (usados quando o acesso é completo)
  public func contactPicker(_ picker: CNContactPickerViewController, didSelect selectedContact: CNContact) {
      if let call = self.bridge?.savedCall(withID: self.pickContactCallbackId ?? "") {
          let contact = ContactPayload(selectedContact.identifier)
          contact.fillData(selectedContact)
          call.resolve(["contact": contact.getJSObject()])
          self.bridge?.releaseCall(call)
      }
  }

}

import UIKit

@available(iOS 14.0, *)
class LimitedContactPickerViewController: UITableViewController {
    
    var contacts: [ContactPayload] = []
    private var sortedContacts: [String: [ContactPayload]] = [:]
    private var sectionTitles: [String] = []
    
    var selectionHandler: ((ContactPayload) -> Void)?
    
  override func viewDidLoad() {
      super.viewDidLoad()
      
      self.title = "Limited Contacts" // Forçar título no header
      
      // 🔹 Garante que a barra de navegação apareça corretamente
      navigationController?.navigationBar.prefersLargeTitles = false
      navigationItem.largeTitleDisplayMode = .never
      
      let closeButton = UIButton(type: .system)
      closeButton.setImage(UIImage(systemName: "xmark.circle.fill"), for: .normal)
      closeButton.tintColor = .systemGray
      closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
      
      navigationItem.rightBarButtonItem = UIBarButtonItem(customView: closeButton)
      
      tableView.register(ContactTableViewCell.self, forCellReuseIdentifier: "contactCell")
      tableView.backgroundColor = .systemGroupedBackground
      tableView.rowHeight = 60
      
      sortContacts()
  }

    
    @objc private func closeTapped() {
        dismiss(animated: true)
    }
    
    // MARK: - Organização por letras A-Z
    private func sortContacts() {
        sortedContacts = Dictionary(grouping: contacts) { contact in
            String(contact.contactDisplayName?.prefix(1) ?? "#").uppercased()
        }
        sectionTitles = sortedContacts.keys.sorted()
    }
    
    override func numberOfSections(in tableView: UITableView) -> Int {
        return sectionTitles.count
    }
    
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return sortedContacts[sectionTitles[section]]?.count ?? 0
    }
    
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "contactCell", for: indexPath) as! ContactTableViewCell
        if let contact = sortedContacts[sectionTitles[indexPath.section]]?[indexPath.row] {
            cell.configure(with: contact)
        }
        return cell
    }
    
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        if let selectedContact = sortedContacts[sectionTitles[indexPath.section]]?[indexPath.row] {
            selectionHandler?(selectedContact)
            dismiss(animated: true)
        }
    }
    
    // 🚫 Removendo índice lateral (letrinhas azuis)
    override func sectionIndexTitles(for tableView: UITableView) -> [String]? {
        return nil
    }
    
    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        return sectionTitles[section]
    }
}

// MARK: - Célula de Contato
@available(iOS 14.0, *)
class ContactTableViewCell: UITableViewCell {
    
    private let contactImageView: UIImageView = {
        let imageView = UIImageView()
        imageView.layer.masksToBounds = true
        imageView.contentMode = .scaleAspectFill
        imageView.translatesAutoresizingMaskIntoConstraints = false
        return imageView
    }()
    
    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: .default, reuseIdentifier: reuseIdentifier)
        accessoryType = .disclosureIndicator
        setupUI()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    private func setupUI() {
        addSubview(contactImageView)
        NSLayoutConstraint.activate([
            contactImageView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 15),
            contactImageView.centerYAnchor.constraint(equalTo: centerYAnchor),
            contactImageView.widthAnchor.constraint(equalToConstant: 44),
            contactImageView.heightAnchor.constraint(equalToConstant: 44)
        ])
        
        // 🛠 Garante que a imagem fique redonda corretamente
        DispatchQueue.main.async {
            self.contactImageView.layer.cornerRadius = self.contactImageView.frame.height / 2
        }
    }
    
    func configure(with contact: ContactPayload) {
        var content = defaultContentConfiguration()
        
        content.text = contact.contactDisplayName ?? "Sem Nome"
        content.secondaryText = contact.firstPhone ?? contact.firstEmail ?? "Sem Informações"
        content.image = contact.loadImage() ?? UIImage(systemName: "person.circle.fill")
        
        // 📸 Melhorando imagem para ficar circular
        content.imageProperties.maximumSize = CGSize(width: 44, height: 44)
        content.imageProperties.cornerRadius = 22
        
        // 🔠 Nome com peso maior (semibold)
        content.textProperties.font = UIFont.systemFont(ofSize: 17, weight: .semibold)
        
        contentConfiguration = content
    }
}

// MARK: - Extensão para carregar imagem
extension ContactPayload {
  var contactDisplayName: String? {
          if let nameDict = self.getJSObject()["name"] as? [String: Any] {
              if let display = nameDict["display"] as? String, !display.isEmpty {
                  return display
              } else {
                  var components = [String]()
                  if let given = nameDict["given"] as? String, !given.isEmpty {
                      components.append(given)
                  }
                  if let middle = nameDict["middle"] as? String, !middle.isEmpty {
                      components.append(middle)
                  }
                  if let family = nameDict["family"] as? String, !family.isEmpty {
                      components.append(family)
                  }
                  if !components.isEmpty {
                      return components.joined(separator: " ")
                  }
              }
          }
          return nil
      }
      
      var firstPhone: String? {
          if let phonesArray = self.getJSObject()["phones"] as? [[String: Any]],
             let firstPhoneObj = phonesArray.first,
             let phone = firstPhoneObj["number"] as? String,
             !phone.isEmpty {
              return phone
          }
          return nil
      }
      
      var firstEmail: String? {
          if let emailsArray = self.getJSObject()["emails"] as? [[String: Any]],
             let firstEmailObj = emailsArray.first,
             let email = firstEmailObj["address"] as? String,
             !email.isEmpty {
              return email
          }
          return nil
      }
    func loadImage() -> UIImage? {
        if let imageDict = getJSObject()["image"] as? [String: Any],
           let base64String = imageDict["base64String"] as? String,
           let imageData = Data(base64Encoded: base64String.components(separatedBy: ",").last ?? ""),
           let image = UIImage(data: imageData) {
            return image
        }
        return nil
    }
}
