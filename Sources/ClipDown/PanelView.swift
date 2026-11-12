import SwiftUI
import ClipCore

let cardWidth: CGFloat = 250
let cardHeight: CGFloat = 238

struct PanelView: View {
    @ObservedObject var state: AppState
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 12) {
            TopBar(state: state, searchFocused: $searchFocused)
            cards
        }
        .padding(.top, 14).padding(.bottom, 16)
        .background(Theme.surface)
        .onAppear { state.ensureSelection() }
        .onChange(of: state.query) { _, _ in state.ensureSelection() }
        .onChange(of: state.currentBoard) { _, _ in state.ensureSelection() }
        .onChange(of: state.searching) { _, on in searchFocused = on }
        .modifier(KeyHandling(state: state))
        .popover(isPresented: $state.previewing, arrowEdge: .top) { previewContent }
    }

    @ViewBuilder private var previewContent: some View {
        if let it = state.item(state.selection) { PreviewView(item: it, state: state) }
    }

    @ViewBuilder private var cards: some View {
        if state.visible.isEmpty {
            Text(state.currentBoard == nil ? "剪贴板历史为空" : "右键卡片,添加到这个固定板")
                .foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 14) {
                        ForEach(Array(state.visible.enumerated()), id: \.element.id) { idx, item in
                            card(item, index: idx)
                        }
                    }
                    .padding(.horizontal, 18).padding(.vertical, 6)
                }
                .onChange(of: state.selection) { _, id in
                    guard let id else { return }
                    withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id, anchor: .center) }
                }
            }
        }
    }

    private func card(_ item: ClipItem, index: Int) -> some View {
        CardView(item: item, index: index + 1, state: state, selected: state.selection == item.id)
            .id(item.id)
            .onTapGesture(count: 2) { state.paste(item) }
            .onTapGesture { state.selection = item.id }
            .contextMenu { menu(for: item) }
    }

    @ViewBuilder private func menu(for item: ClipItem) -> some View {
        Button("粘贴  ↩") { state.paste(item) }
        Button("以纯文本粘贴  \(Settings.shared.plainShortcut.display)") { state.paste(item, plain: true) }
        if state.plugins.actions(for: item).contains(where: { $0.id == "md2rich.convert" }) {
            Button("转为富文本粘贴  \(Settings.shared.markdownShortcut.display)") { state.pasteAsMarkdown(item) }
        }
        Button("仅复制") { state.copyOnly(item) }
        Divider()
        Menu("添加到固定板") {
            ForEach(state.store.boards) { b in
                Button { state.store.assign(item.id, to: b.id) } label: {
                    Label(b.name, systemImage: item.boardID == b.id ? "checkmark.circle.fill" : "circle.fill")
                }
            }
            if !state.store.boards.isEmpty { Divider() }
            Button("新建固定板…") { state.beginNewBoard(); if let b = state.currentBoard { state.store.assign(item.id, to: b) } }
        }
        if item.boardID != nil { Button("从固定板移除") { state.store.assign(item.id, to: nil) } }
        let actions = state.plugins.actions(for: item)
        if !actions.isEmpty {
            Divider()
            ForEach(actions) { a in Button { state.run(a, on: item) } label: { Label(a.title, systemImage: a.symbol) } }
        }
        Divider()
        Button("删除", role: .destructive) { state.store.remove(item.id) }
    }
}

// MARK: - Top bar (search · pinboard tabs · menu)

struct TopBar: View {
    @ObservedObject var state: AppState
    var searchFocused: FocusState<Bool>.Binding
    @FocusState private var boardFocused: Bool

    var body: some View {
        ZStack {
            HStack(spacing: 6) {
                tab(label: "剪贴板", symbol: "clock.arrow.circlepath", color: nil, board: nil)
                ForEach(state.store.boards) { b in
                    Group {
                        if state.editingBoard == b.id {
                            editingTab(color: Color(hex: b.colorHex))
                        } else {
                            tab(label: b.name, symbol: nil, color: Color(hex: b.colorHex), board: b.id)
                        }
                    }
                    .contextMenu { boardMenu(b) }
                }
                Button { state.beginNewBoard() } label: {
                    Image(systemName: "plus").font(.system(size: 13, weight: .medium))
                        .frame(width: 28, height: 26).foregroundStyle(.secondary)
                }.buttonStyle(.plain)
            }
            HStack {
                searchArea
                Spacer()
                optionsMenu
            }
            .padding(.horizontal, 18)
        }
        .frame(height: 30)
    }

    /// Name field that appears in place of the tab while creating / renaming a board.
    private func editingTab(color: Color) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 10, height: 10)
            TextField("", text: $state.editingText)
                .textFieldStyle(.plain).font(.system(size: 12))
                .focused($boardFocused).frame(width: 90)
                .onSubmit { state.commitEdit() }
        }
        .padding(.horizontal, 10).frame(height: 26)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.accentColor, lineWidth: 2))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.accentColor.opacity(0.35), lineWidth: 4).padding(-3))
        .onAppear { DispatchQueue.main.async { boardFocused = true } }
        .onChange(of: boardFocused) { _, focused in
            if !focused && state.editingBoard != nil { state.commitEdit() }
        }
    }

    /// Right-click on a board tab: rename, delete, and a row of colour swatches.
    @ViewBuilder private func boardMenu(_ b: Board) -> some View {
        Button("重命名") { state.beginRename(b) }
        Button("删除", role: .destructive) { state.deleteBoard(b) }
        Divider()
        Picker("颜色", selection: Binding(get: { b.colorHex }, set: { state.store.setBoardColor(b.id, hex: $0) })) {
            ForEach(boardPalette, id: \.self) { hex in
                Label(hex, systemImage: "circle.fill").tint(Color(hex: hex)).tag(hex)
            }
        }
        .pickerStyle(.palette)
        .paletteSelectionEffect(.symbolVariant(.fill))
    }

    private func tab(label: String, symbol: String?, color: Color?, board: UUID?) -> some View {
        let selected = state.currentBoard == board
        return Button { state.currentBoard = board } label: {
            HStack(spacing: 6) {
                if let s = symbol { Image(systemName: s).font(.system(size: 12)) }
                if let c = color { Circle().fill(c).frame(width: 10, height: 10) }
                Text(label).font(.system(size: 12, weight: selected ? .semibold : .regular))
            }
            .padding(.horizontal, 10).frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Color.primary.opacity(0.12) : .clear))
            .foregroundStyle(selected ? .primary : .secondary)
            .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    @ViewBuilder private var searchArea: some View {
        HStack(spacing: 8) {
            Button { state.searching ? state.endSearch() : state.beginSearch() } label: {
                Image(systemName: "magnifyingglass").font(.system(size: 14)).foregroundStyle(.secondary)
            }.buttonStyle(.plain)
            if state.searching {
                TextField("搜索", text: $state.query)
                    .textFieldStyle(.plain).font(.system(size: 13))
                    .focused(searchFocused).frame(width: 180)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.08)))
                    .onAppear { searchFocused.wrappedValue = true }
            }
        }
    }

    private var optionsMenu: some View {
        Menu {
            Section("插件") {
                ForEach(state.plugins.plugins, id: \.id) { p in
                    Toggle(p.name, isOn: Binding(get: { state.plugins.isEnabled(p) }, set: { state.plugins.setEnabled(p, $0) }))
                    if p.supportsAutoRun {
                        Toggle("  复制时自动处理", isOn: Binding(get: { state.plugins.isAutoRun(p) }, set: { state.plugins.setAutoRun(p, $0) }))
                            .disabled(!state.plugins.isEnabled(p))
                    }
                }
            }
            Divider()
            Button("设置…") { (NSApp.delegate as? AppDelegate)?.openSettings() }
            Button("清空历史(保留固定板内容)") { state.store.clear() }
            Button("退出 ClipDown") { NSApp.terminate(nil) }
        } label: {
            Image(systemName: "ellipsis").font(.system(size: 15, weight: .semibold)).foregroundStyle(.secondary)
                .frame(width: 28, height: 26)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
    }
}

// MARK: - Card

struct CardView: View {
    let item: ClipItem
    let index: Int
    @ObservedObject var state: AppState
    let selected: Bool

    private var title: String {
        switch item.kind {
        case .image: return "图片"
        case .file: return "\(item.filePaths.count) 个文件"
        case .text: return item.linkURL != nil ? "链接" : (item.isRich ? "富文本" : "文本")
        }
    }

    private var fallbackColor: Color {
        switch item.kind {
        case .image: return Color(red: 0.55, green: 0.35, blue: 0.85)
        case .file: return Color(red: 0.2, green: 0.5, blue: 0.9)
        case .text: return item.linkURL != nil ? Color(red: 0.1, green: 0.5, blue: 0.9) : Color(red: 0.25, green: 0.28, blue: 0.33)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            bodyContent.frame(maxWidth: .infinity, maxHeight: .infinity)
            footer
        }
        .frame(width: cardWidth, height: cardHeight)
        .background(Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12)
            .stroke(selected ? Color.accentColor : Theme.cardStroke, lineWidth: selected ? 3 : 1))
        .shadow(color: .black.opacity(0.12), radius: 4, y: 2)
    }

    private var header: some View {
        let color = AppIcons.color(item.sourceBundleID, fallback: fallbackColor)
        return ZStack(alignment: .leading) {
            color
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 15, weight: .bold))
                    Text(relativeFormatter.localizedString(for: item.date, relativeTo: Date()))
                        .font(.system(size: 11)).opacity(0.85)
                }
                .foregroundStyle(.white).padding(.leading, 12)
                Spacer(minLength: 0)
            }
            HStack {
                Spacer()
                ZStack {
                    if let icon = AppIcons.icon(item.sourceBundleID) {
                        Image(nsImage: icon).resizable().scaledToFit().frame(width: 74, height: 74)
                    } else {
                        Image(systemName: item.kind == .image ? "photo" : "doc.text")
                            .font(.system(size: 34)).foregroundStyle(.white.opacity(0.85))
                    }
                }
                .frame(width: 74, height: 74).offset(x: 12, y: 4)
            }
        }
        .frame(height: 62)
        .clipped()
        .overlay(alignment: .topTrailing) {
            if item.boardID != nil {
                Image(systemName: "pin.fill").font(.system(size: 9)).foregroundStyle(.white).padding(6)
                    .background(Circle().fill(.black.opacity(0.35))).padding(4).offset(x: -52)
            }
        }
    }

    @ViewBuilder private var bodyContent: some View {
        switch item.kind {
        case .image:
            if let img = state.store.thumbnail(for: item) {
                Image(nsImage: img).resizable().scaledToFit().padding(8)
            }
        case .file:
            fileBody
        case .text:
            if let thumb = RichThumb.image(for: item, size: CGSize(width: cardWidth, height: cardHeight - 62 - 26)) {
                Image(nsImage: thumb).resizable().frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .background(Color.white)
                    .mask(fade)
            } else if let url = item.linkURL {
                VStack(alignment: .leading, spacing: 6) {
                    Text(url.host ?? "").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.cardText)
                    Text(url.absoluteString).font(.system(size: 11)).foregroundStyle(Theme.link).lineLimit(6)
                }
                .padding(12).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                Text(String((item.text ?? "").prefix(600)))
                    .font(.system(size: 12)).lineSpacing(2).foregroundStyle(Theme.cardText)
                    .padding(12).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .mask(fade)
            }
        }
    }

    private var fileBody: some View {
        let first = item.filePaths.first ?? ""
        return VStack(spacing: 8) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: first)).resizable().scaledToFit().frame(width: 72, height: 72)
            Text(item.filePaths.map { ($0 as NSString).lastPathComponent }.joined(separator: "\n"))
                .font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.cardText.opacity(0.7))
                .lineLimit(3).multilineTextAlignment(.center)
        }
        .padding(10).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var fade: some View {
        LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.78),
                               .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom)
    }

    private var footer: some View {
        HStack {
            Text(footerLeft).font(.system(size: 11)).foregroundStyle(Theme.cardSecondary)
            Spacer()
            HStack(spacing: 3) {
                Image(systemName: "text.alignleft").font(.system(size: 9))
                Text("\(index)").font(.system(size: 11))
            }.foregroundStyle(Theme.cardSecondary)
        }
        .padding(.horizontal, 12).frame(height: 26)
    }

    private var footerLeft: String {
        switch item.kind {
        case .text: return "\((item.text ?? "").count) 个字符"
        case .image:
            if let i = state.store.thumbnail(for: item), let r = i.representations.first {
                return "\(r.pixelsWide) × \(r.pixelsHigh)"
            }
            return ""
        case .file: return ""
        }
    }
}

// MARK: - Preview popover

struct PreviewView: View {
    let item: ClipItem
    @ObservedObject var state: AppState

    var body: some View {
        ScrollView {
            Group {
                if item.kind == .image, let img = state.store.thumbnail(for: item) {
                    Image(nsImage: img).resizable().scaledToFit()
                } else if let a = RichText.attributed(from: item) {
                    Text(AttributedString(a))
                } else {
                    Text(item.text ?? "").font(.system(size: 13, design: .monospaced))
                }
            }
            .textSelection(.enabled).padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(item.rtf != nil && item.kind == .text ? Color.white : Color.clear)
        }
        .frame(width: 480, height: 360)
    }
}

// MARK: - Keys

struct KeyHandling: ViewModifier {
    @ObservedObject var state: AppState

    func body(content: Content) -> some View {
        content
            .onKeyPress(.leftArrow) { state.move(-1); return .handled }
            .onKeyPress(.rightArrow) { state.move(1); return .handled }
            .onKeyPress(.space, phases: .down) { _ in
                guard !state.isTyping else { return .ignored }
                state.previewing.toggle(); return .handled
            }
            .onKeyPress(.delete) {
                guard !state.isTyping, let it = state.item(state.selection) else { return .ignored }
                state.move(1); state.store.remove(it.id); return .handled
            }
            .onKeyPress(.tab) { guard !state.isTyping else { return .ignored }; state.cycleBoard(); return .handled }
            .onKeyPress(characters: .decimalDigits, phases: .down) { press in
                guard press.modifiers.contains(.command), let n = Int(press.characters), n >= 1 else { return .ignored }
                let v = state.visible
                if n <= v.count { state.paste(v[n - 1]) }
                return .handled
            }
            .onKeyPress(characters: CharacterSet(charactersIn: "cpf"), phases: .down) { press in
                guard press.modifiers.contains(.command) else { return .ignored }
                switch press.characters {
                case "f": state.beginSearch()
                case "c": if let it = state.item(state.selection) { state.copyOnly(it) }
                case "p": if let it = state.item(state.selection) { state.quickPin(it) }
                default: return .ignored
                }
                return .handled
            }
            // Start typing anywhere -> open search with that character.
            .onKeyPress(phases: .down) { press in
                guard !state.isTyping, press.modifiers.isDisjoint(with: [.command, .control, .option]),
                      let c = press.characters.first, c.isLetter || c.isNumber || c.isPunctuation else { return .ignored }
                state.beginSearch(with: press.characters)
                return .handled
            }
    }
}
