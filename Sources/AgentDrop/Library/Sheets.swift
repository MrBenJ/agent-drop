import AgentDropApp
import AgentDropCore
import SwiftUI

/// Spec §6 **Edit metadata**. The kind picker is disabled while a handoff is claimed or done.
struct EditMetadataSheet: View {
    let library: LibraryModel
    let drop: Drop
    @State private var form: MetadataForm
    @State private var error: String?
    @State private var saving = false
    @Environment(\.dismiss) private var dismiss

    init(library: LibraryModel, drop: Drop) {
        self.library = library
        self.drop = drop
        _form = State(initialValue: MetadataForm(drop))
    }

    var body: some View {
        SheetLayout(title: "Edit Metadata", error: error, confirm: "Save", busy: saving, onCancel: { dismiss() }) {
            saving = true
            error = await library.edit(drop.id, form)
            saving = false
            if error == nil { dismiss() }
        } content: {
            TextField("Title", text: $form.title)
            TextField("Description", text: $form.description, axis: .vertical).lineLimit(3...6)
            TextField("Project", text: $form.project)
            TagEditor(tags: $form.tags, pending: $form.pendingTag)
            Picker("Kind", selection: $form.kind) {
                Text("Note").tag(DropKind.note)
                Text("Handoff").tag(DropKind.handoff)
            }
            .disabled(!MetadataForm.canChangeKind(drop))
            .help(MetadataForm.canChangeKind(drop) ? "" : "Release or reopen this handoff before changing its kind.")
        }
    }
}

/// Spec §3.2 **Register**: title, description, from, project, tags, kind.
struct RegisterSheet: View {
    let library: LibraryModel
    let entry: UnregisteredEntry
    @State private var form = RegisterForm()
    @State private var error: String?
    @State private var saving = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        SheetLayout(title: "Register “\(entry.name)”", error: error, confirm: "Register", busy: saving,
                    onCancel: { dismiss() }) {
            saving = true
            error = await library.register(entry, form)
            saving = false
            if error == nil { dismiss() }
        } content: {
            TextField("Title", text: $form.title, prompt: Text("From the first # heading, else the filename"))
            TextField("Description", text: $form.description, axis: .vertical).lineLimit(3...6)
            TextField("From", text: $form.from, prompt: Text("Required: who or what made this"))
            TextField("Project", text: $form.project)
            TagEditor(tags: $form.tags, pending: $form.pendingTag)
            Toggle("Handoff (appears in the Inbox for an agent to claim)", isOn: $form.handoff)
        }
    }
}

/// **Mark done** with an optional note (like `drop done --note`).
struct DoneSheet: View {
    let library: LibraryModel
    let drop: Drop
    @State private var note = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        SheetLayout(title: "Mark “\(drop.title)” Done", error: nil, confirm: "Mark Done", busy: false,
                    onCancel: { dismiss() }) {
            await library.markDone(drop.id, note: note)
            dismiss()
        } content: {
            TextField("Note", text: $note, prompt: Text("Optional, e.g. shipped in PR #42"))
        }
    }
}

struct SheetLayout<Content: View>: View {
    let title: String
    let error: String?
    let confirm: String
    let busy: Bool
    let onCancel: () -> Void
    let onConfirm: () async -> Void
    @ViewBuilder let content: Content

    init(title: String, error: String?, confirm: String, busy: Bool, onCancel: @escaping () -> Void,
         onConfirm: @escaping () async -> Void, @ViewBuilder content: () -> Content) {
        self.title = title
        self.error = error
        self.confirm = confirm
        self.busy = busy
        self.onCancel = onCancel
        self.onConfirm = onConfirm
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.headline)
            Form { content }
            if let error {
                Text(error).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel).keyboardShortcut(.cancelAction)
                Button(confirm) { Task { await onConfirm() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(busy)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}

/// Tags as removable tokens plus a field to add one (tags may contain commas or spaces).
struct TagEditor: View {
    @Binding var tags: [String]
    /// Lives in the form, so a tag typed but not added with Return is still saved.
    @Binding var pending: String

    var body: some View {
        LabeledContent("Tags") {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(tags, id: \.self) { tag in
                    HStack(spacing: 4) {
                        Text(tag)
                        Button {
                            tags.removeAll { $0 == tag }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .buttonStyle(.borderless)
                        .help("Remove \(tag)")
                    }
                }
                TextField("Add a tag", text: $pending)
                    .onSubmit {
                        tags = TagList.normalized(tags + [pending])
                        pending = ""
                    }
            }
        }
    }
}
