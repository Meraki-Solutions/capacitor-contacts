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

// MARK: - UI Customizada para exibir contatos limitados
// Essa classe cria uma interface simples com uma lista (table view) para que o usuário selecione

import UIKit

@available(iOS 14.0, *)
class LimitedContactPickerViewController: UITableViewController {
    // Array de contatos (modelo ContactPayload)
    var contacts: [ContactPayload] = []
    // Callback para retornar o contato selecionado
    var selectionHandler: ((ContactPayload) -> Void)?

    override func viewDidLoad() {
        super.viewDidLoad()
        
        // Registro da célula padrão
        self.tableView.register(UITableViewCell.self, forCellReuseIdentifier: "contactCell")
        
        // Define o título com suporte a multilíngua
        self.title = NSLocalizedString("Lista de contatos permitidos", comment: "Título da lista de contatos permitidos")
        
        // Adiciona um botão fechar (ícone) no canto superior direito
        self.navigationItem.rightBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "xmark"),
            style: .plain,
            target: self,
            action: #selector(closeTapped)
        )
      self.tableView.contentInset = UIEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)

        // Adiciona um cabeçalho vazio para dar espaçamento no topo (por exemplo, 20 pontos)
        let headerView = UIView(frame: CGRect(x: 0, y: 0, width: tableView.frame.width, height: 20))
        headerView.backgroundColor = .clear
        self.tableView.tableHeaderView = headerView
    }
    
    @objc func closeTapped() {
        self.dismiss(animated: true, completion: nil)
    }
    
    // Número de linhas = número de contatos
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return contacts.count
    }
    
    // Configuração da célula com foto, texto e layout ajustado
  override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    let cell = tableView.dequeueReusableCell(withIdentifier: "contactCell", for: indexPath)
    let contact = contacts[indexPath.row]
    
    // Configuração padrão do conteúdo da célula
    var content = cell.defaultContentConfiguration()
    
    // Define o texto de exibição:
    // 1. Se houver nome (contactDisplayName), usa-o.
    // 2. Senão, se houver email, usa o primeiro email.
    // 3. Senão, se houver telefone, usa o primeiro telefone.
    // 4. Caso contrário, exibe "Sem dados".
    var displayText = ""
    if let name = contact.contactDisplayName, !name.isEmpty {
      displayText = name
    } else if let email = contact.firstEmail, !email.isEmpty {
      displayText = email
    } else if let phone = contact.firstPhone, !phone.isEmpty {
      displayText = phone
    } else {
      displayText = NSLocalizedString("Sem dados", comment: "Nenhuma informação disponível")
    }
    content.text = displayText
    
    // Configura a imagem à esquerda:
    let jsObject = contact.getJSObject()
    print("JSObject para o contato \(contact.contactId): \(jsObject)")
    if let imageDict = jsObject["image"] as? [String: Any],
       let base64String = imageDict["base64String"] as? String {
      print("Base64 String encontrada para o contato \(contact.contactId): \(base64String)")
      let base64DataString = base64String.components(separatedBy: ",").last ?? ""
      if let imageData = Data(base64Encoded: base64DataString),
         let image = UIImage(data: imageData) {
        print("Imagem decodificada com sucesso para o contato \(contact.contactId)")
        content.image = image
      } else {
        print("Erro ao criar UIImage para o contato \(contact.contactId)")
        content.image = UIImage(systemName: "person.circle")
      }
    } else {
      print("Campo 'image' inválido ou ausente para o contato \(contact.contactId)")
      content.image = UIImage(systemName: "person.circle")
    }
    
    // Ajusta o tamanho e o estilo da imagem
    content.imageProperties.maximumSize = CGSize(width: 30, height: 30)
    content.imageProperties.cornerRadius = 20
    
    // Aplica o conteúdo configurado à célula
    cell.contentConfiguration = content
    
    // Remove o accessoryType
    cell.accessoryType = .none
    
    return cell
  }
  
    // Ao selecionar um contato, chama o callback e fecha a tela
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let selectedContact = contacts[indexPath.row]
        selectionHandler?(selectedContact)
        self.dismiss(animated: true, completion: nil)
    }
}

extension ContactPayload {
    /// Retorna o nome formatado do contato.
    var contactDisplayName: String? {
        if let nameDict = self.getJSObject()["name"] as? [String: Any] {
            // Tenta utilizar o displayName
            if let display = nameDict["display"] as? String, !display.isEmpty {
                return display
            } else {
                // Se não houver display, concatena os componentes disponíveis
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
    
    /// Retorna o primeiro email, se disponível.
    var firstEmail: String? {
        if let emailsArray = self.getJSObject()["emails"] as? [Any],
           let firstEmailObj = emailsArray.first as? [String: Any],
           let email = firstEmailObj["address"] as? String,
           !email.isEmpty {
            return email
        }
        return nil
    }
    
    /// Retorna o primeiro telefone, se disponível.
    var firstPhone: String? {
        if let phonesArray = self.getJSObject()["phones"] as? [Any],
           let firstPhoneObj = phonesArray.first as? [String: Any],
           let phone = firstPhoneObj["number"] as? String,
           !phone.isEmpty {
            return phone
        }
        return nil
    }
}
