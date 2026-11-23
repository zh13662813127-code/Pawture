import DesktopCatsCore
import SwiftUI
import UniformTypeIdentifiers

private enum AppSection: String, CaseIterable, Identifiable {
    case scene
    case cats

    var id: String { rawValue }
    var title: String { self == .scene ? "桌面活动" : "我的猫咪" }
    var symbol: String { self == .scene ? "sparkles.rectangle.stack" : "pawprint.fill" }
}

struct ContentView: View {
    @ObservedObject var store: CatStore
    @State private var section: AppSection = .scene
    @State private var selectedCatID: UUID?
    @State private var photoTargetID: UUID?
    @State private var showingImporter = false
    @State private var showingError = false
    @State private var errorMessage = ""
    @State private var importing = false

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(Palette.line).frame(width: 1)
            VStack(spacing: 0) {
                header
                Rectangle().fill(Palette.line).frame(height: 1)
                if section == .scene {
                    scenePage
                } else {
                    CatEditorView(store: store, selectedCatID: $selectedCatID, onChoosePhoto: choosePhoto)
                }
            }
        }
        .background(Palette.paper)
        .fileImporter(
            isPresented: $showingImporter,
            allowedContentTypes: [.image],
            allowsMultipleSelection: false,
            onCompletion: importPhoto
        )
        .alert("猫咪照片", isPresented: $showingError) {
            Button("好", role: .cancel) { }
        } message: {
            Text(errorMessage)
        }
        .overlay {
            if importing {
                ZStack {
                    Color.black.opacity(0.18).ignoresSafeArea()
                    HStack(spacing: 11) {
                        ProgressView()
                        Text("正在本机生成猫咪剪影…")
                            .font(.system(size: 13, weight: .medium))
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 14)
                    .background(.white, in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
        .onAppear {
            if selectedCatID == nil { selectedCatID = store.cats.first?.id }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "pawprint.fill")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(Palette.terracotta)
                    .frame(width: 38, height: 38)
                    .background(.white.opacity(0.8), in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 2) {
                    Text("爪影")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Palette.ink)
                    Text("Pawture")
                        .font(.system(size: 9, weight: .medium, design: .rounded))
                        .foregroundStyle(Palette.muted)
                }
            }
            .padding(.bottom, 18)

            ForEach(AppSection.allCases) { item in
                Button {
                    section = item
                    if selectedCatID == nil { selectedCatID = store.cats.first?.id }
                } label: {
                    HStack(spacing: 11) {
                        Image(systemName: item.symbol)
                            .font(.system(size: 14, weight: .medium))
                            .frame(width: 20)
                        Text(item.title)
                            .font(.system(size: 13, weight: .medium))
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(section == item ? Palette.ink : Palette.muted)
                    .padding(.horizontal, 12)
                    .frame(height: 40)
                    .background(section == item ? .white : .clear, in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
            }

            Spacer(minLength: 20)

            HStack(spacing: 7) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 10, weight: .semibold))
                Text("照片只保存在这台 Mac")
                    .font(.system(size: 10, weight: .medium))
            }
            .foregroundStyle(Palette.muted)
            .padding(.horizontal, 8)
            .padding(.bottom, 3)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 19)
        .frame(width: 190)
        .background(Palette.sidebar)
    }

    private var header: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(section.title)
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                Text("桌面猫咪 · 试运行")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Palette.muted)
            }
            Spacer()
            HStack(spacing: 8) {
                Circle()
                    .fill(store.overlayVisible ? Palette.leaf : Palette.muted)
                    .frame(width: 8, height: 8)
                Text(store.overlayVisible ? "桌面猫咪在线" : "桌面猫咪已隐藏")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Palette.muted)
            }
            Picker("互动模式", selection: $store.mode) {
                ForEach(CompanionMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 168)
        }
        .padding(.horizontal, 23)
        .padding(.vertical, 17)
    }

    private var scenePage: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 18) {
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(store.overlayVisible ? Palette.leaf : Palette.muted)
                            .frame(width: 8, height: 8)
                        Text(store.overlayVisible ? "猫咪正在桌面活动" : "猫咪暂时休息")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(Palette.ink)
                    }
                    Text(store.mode == .mischief ? "捣乱模式" : "陪伴模式")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Palette.muted)
                }
                Spacer()
                encounterMenu
                Button {
                    store.soundEnabled.toggle()
                } label: {
                    Image(systemName: store.soundEnabled ? "speaker.wave.2" : "speaker.slash")
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.borderless)
                .help(store.soundEnabled ? "静音" : "打开猫咪声音")
                .accessibilityLabel(store.soundEnabled ? "静音" : "打开猫咪声音")
                Picker("季节作息", selection: $store.seasonSetting) {
                    ForEach(SeasonSetting.allCases, id: \.self) { setting in
                        Text(setting.title).tag(setting)
                    }
                }
                .pickerStyle(.menu)
                .fixedSize()
                Divider().frame(height: 18)
                Toggle("显示桌面猫咪", isOn: $store.overlayVisible)
                    .toggleStyle(.switch)
                    .tint(Palette.leaf)
                    .font(.system(size: 12, weight: .medium))
                    .fixedSize()
            }
            .padding(20)
            .background(.white.opacity(0.72), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Palette.line, lineWidth: 1))

            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 330), spacing: 14)], spacing: 14) {
                    ForEach(store.cats) { cat in
                        CatActionCard(cat: cat, store: store) {
                            selectedCatID = cat.id
                            section = .cats
                        }
                    }
                }
                .padding(1)
            }

            HStack(spacing: 8) {
                Image(systemName: "pawprint")
                    .foregroundStyle(Palette.terracotta)
                Text(store.overlayVisible ? store.latestEvent : "桌面猫咪已隐藏")
                    .foregroundStyle(Palette.muted)
            }
            .font(.system(size: 11, weight: .medium))

            Spacer(minLength: 0)
        }
        .padding(18)
    }

    private var encounterMenu: some View {
        let cats = store.cats.filter { $0.rigBlueprint != nil }
        return Menu {
            if cats.count == 2 {
                encounterOptions(cats[0], cats[1])
            } else {
                ForEach(cats.indices, id: \.self) { i in
                    ForEach(cats.dropFirst(i + 1)) { other in
                        Menu("\(cats[i].name)和\(other.name)") { encounterOptions(cats[i], other) }
                    }
                }
            }
        } label: {
            Label("猫咪互动", systemImage: "pawprint")
        }
        .fixedSize()
        .disabled(cats.count < 2)
        .help("在桌面上试演两只猫的互动")
    }

    @ViewBuilder
    private func encounterOptions(_ first: CatProfile, _ second: CatProfile) -> some View {
        ForEach(EncounterKind.allCases, id: \.self) { kind in
            Button(kind.title) { store.preview(kind, between: first, and: second) }
                .disabled(kind == .chase && store.mode != .mischief)
        }
    }

    private func choosePhoto(for id: UUID) {
        photoTargetID = id
        showingImporter = true
    }

    private func importPhoto(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result,
              let sourceURL = urls.first,
              let targetID = photoTargetID else { return }
        importing = true
        Task {
            do {
                let cutoutPath = try await CatPhotoProcessor.makeLocalCutout(from: sourceURL)
                let rigBlueprint = try? await CatPoseAnalyzer.analyze(cutoutPath)
                if let index = store.cats.firstIndex(where: { $0.id == targetID }) {
                    var updated = store.cats[index]
                    updated.bundleImageName = nil
                    updated.imagePath = cutoutPath.path
                    updated.rigBlueprint = rigBlueprint
                    store.update(updated)
                    store.latestEvent = rigBlueprint == nil
                        ? "\(updated.name)的照片已保存，请更换一张脸和身体清晰的照片以启用动作。"
                        : "\(updated.name)已建立本机动作骨架。"
                }
                if rigBlueprint == nil {
                    errorMessage = "已保存照片，但没能定位猫的身体。可以更换为脸和身体轮廓清晰的一张照片。"
                    showingError = true
                }
            } catch {
                errorMessage = error.localizedDescription
                showingError = true
            }
            importing = false
        }
    }
}

private struct CatActionCard: View {
    let cat: CatProfile
    @ObservedObject var store: CatStore
    let edit: () -> Void
    @State private var action = CatAction.watch
    @State private var started = Date.now
    @State private var deadline = Date.distantFuture
    @State private var napEnd: Date?
    @State private var bellyEnd: Date?
    @State private var taps = CatTapResponder()
    @State private var tracker = PettingTracker()
    @State private var surface = CatTouchSurface()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(cat.name).font(.headline)
                Spacer()
                Button("性格与形象", action: edit)
                    .buttonStyle(.link)
                    .foregroundStyle(Palette.leaf)
            }
            TimelineView(.animation(minimumInterval: 1.0 / 16)) { frame in
                RiggedCatPhotoView(profile: cat, action: action,
                                   elapsed: max(0, frame.date.timeIntervalSince(started)),
                                   onVisibleFrame: { surface.present($0, for: cat.photoURL) },
                                   onClipReady: { ready in
                                       guard ready == action, ready.waitsForTouchClip, deadline == .distantFuture else { return }
                                       deadline = Date.now.addingTimeInterval(BehaviorEngine.hold(ready,
                                                        personality: cat.personality, winter: 0, roll: 0))
                                   })
                    .frame(width: 210, height: 210)
                    .overlay { PreviewPettingInput(sample: touch, tap: tap) }
                    .accessibilityElement(children: .ignore)
                    .accessibilityAddTraits(.isImage)
                    .accessibilityLabel(cat.name)
                    .accessibilityValue(action.title)
                    .accessibilityIdentifier("panel-cat-\(cat.id)")
            }
            .frame(maxWidth: .infinity)
            .background(Palette.stageSky, in: RoundedRectangle(cornerRadius: 8))
            if cat.rigBlueprint == nil {
                Button("设置猫咪照片", action: edit)
            } else {
                HStack {
                    ForEach([CatAction.wander, .loaf, .nap, .wakeStretch, .petRub, .bellyUp]) { pose in
                        Button {
                            store.preview(pose, for: cat)
                        } label: {
                            Text(label(pose))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .tint(action == pose ? Palette.leaf : Palette.ink)
                        .accessibilityLabel("\(cat.name) · \(label(pose))")
                    }
                }
            }
        }
        .padding(15)
        .background(.white.opacity(0.8), in: RoundedRectangle(cornerRadius: 10))
        .onChange(of: store.poseRequest?.id) { _, _ in
            guard let request = store.poseRequest, request.catID == cat.id else { return }
            tracker = PettingTracker()
            begin(request.action)
        }
        .task(id: deadline) {
            guard deadline != .distantFuture else { return }
            do { try await Task.sleep(for: .seconds(max(0, deadline.timeIntervalSinceNow))) } catch { return }
            guard !Task.isCancelled,
                  let next = BehaviorEngine.afterTouch(action, napExpired: napEnd.map { $0 <= .now } ?? false,
                                                       bellyExpired: bellyEnd.map { $0 <= .now } ?? false) else { return }
            begin(next)
        }
    }

    private func touch(_ point: CGPoint?, in bounds: CGRect) {
        guard cat.rigBlueprint != nil else { return }
        let contact = point.flatMap { surface.contains($0, in: bounds, url: cat.photoURL) ? $0 : nil }
        if let response = tracker.sample(contact, at: ProcessInfo.processInfo.systemUptime,
                    action: action, personality: cat.personality, roll: Double.random(in: 0..<1)) {
            respond(response)
        }
    }

    private func tap(_ point: CGPoint, in bounds: CGRect) {
        guard cat.rigBlueprint != nil, surface.contains(point, in: bounds, url: cat.photoURL) else { return }
        if let response = taps.tap(at: ProcessInfo.processInfo.systemUptime, action: action,
                                   personality: cat.personality, roll: .random(in: 0..<1)) {
            respond(response)
        }
    }

    private func respond(_ response: CatAction) {
        store.voice(for: response, from: action)
        store.latestEvent = cat.name + response.title + "。"
        begin(response)
    }

    private func begin(_ next: CatAction) {
        let now = Date.now
        let winter = store.seasonSetting.winterBias(month: Calendar.current.component(.month, from: now))
        let end = now.addingTimeInterval(BehaviorEngine.hold(next, personality: cat.personality,
                                                             winter: winter, roll: .random(in: 0..<1)))
        if next == .bellyUp {
            deadline = action == .bellyNuzzle ? (bellyEnd ?? end) : end
            bellyEnd = deadline
            napEnd = nil
        } else if next == .nap {
            deadline = action == .sleepMurmur ? (napEnd ?? end) : end
            napEnd = deadline
        } else if next.waitsForTouchClip && (action != next || deadline == .distantFuture) && cat.rigBlueprint != nil {
            deadline = .distantFuture
            if next != .sleepMurmur { napEnd = nil }
        } else {
            deadline = BehaviorEngine.afterTouch(next) == nil ? .distantFuture : end
            if next != .sleepMurmur { napEnd = nil }
        }
        if next != .bellyUp && next != .bellyNuzzle { bellyEnd = nil }
        action = next
        started = now
    }

    private func label(_ action: CatAction) -> String {
        switch action {
        case .loaf: "侧卧"
        case .nap: "蜷睡"
        case .wakeStretch: "睡醒"
        case .petRub: "蹭手"
        case .bellyUp: "翻肚皮"
        default: "走路"
        }
    }
}

private struct CatEditorView: View {
    @ObservedObject var store: CatStore
    @Binding var selectedCatID: UUID?
    let onChoosePhoto: (UUID) -> Void

    private var selectedProfile: CatProfile? {
        store.cats.first(where: { $0.id == selectedCatID })
    }

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("猫咪")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Palette.muted)
                    Spacer()
                    Button {
                        selectedCatID = store.addCat()
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Palette.leaf)
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.plain)
                    .help("添加猫咪")
                }
                ForEach(store.cats) { cat in
                    Button {
                        selectedCatID = cat.id
                    } label: {
                        HStack(spacing: 9) {
                            CatPhotoView(profile: cat)
                                .frame(width: 37, height: 44)
                                .background(Palette.stageSky, in: RoundedRectangle(cornerRadius: 6))
                            Text(cat.name)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(Palette.ink)
                            Spacer(minLength: 0)
                        }
                        .padding(7)
                        .background(selectedCatID == cat.id ? .white : .clear, in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            .padding(14)
            .frame(width: 194)
            .frame(maxHeight: .infinity)
            .background(.white.opacity(0.66), in: RoundedRectangle(cornerRadius: 8))

            if let profile = selectedProfile {
                profileEditor(profile)
            } else {
                ContentUnavailableView("还没有猫咪", systemImage: "pawprint", description: Text("添加一只猫咪开始设置。"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(18)
        .onAppear {
            if selectedCatID == nil { selectedCatID = store.cats.first?.id }
        }
    }

    private func profileEditor(_ profile: CatProfile) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 17) {
                HStack(alignment: .center, spacing: 22) {
                    CatPhotoView(profile: profile)
                        .frame(width: 196, height: 234)
                        .background(Palette.stageSky, in: RoundedRectangle(cornerRadius: 8))

                    VStack(alignment: .leading, spacing: 13) {
                        Text("专属形象")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Palette.muted)
                        TextField("猫咪名字", text: nameBinding(for: profile))
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 15, weight: .medium))
                            .frame(maxWidth: 270)
                        Button {
                            onChoosePhoto(profile.id)
                        } label: {
                            Label("更换照片", systemImage: "photo.badge.plus")
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .buttonStyle(.bordered)
                        .tint(Palette.leaf)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.bottom, 2)

                Rectangle().fill(Palette.line).frame(height: 1)

                VStack(alignment: .leading, spacing: 4) {
                    Text("性格")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Palette.ink)
                    Text("每一项都可以单独调整")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.muted)
                }

                ForEach(CatTrait.allCases) { trait in
                    HStack(spacing: 16) {
                        Text(trait.title)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Palette.ink)
                            .frame(width: 50, alignment: .leading)
                        Slider(value: traitBinding(trait, profile: profile), in: 0...1)
                            .tint(Palette.leaf)
                        Text("\(Int(profile.personality.value(for: trait) * 100))")
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                            .foregroundStyle(Palette.muted)
                            .monospacedDigit()
                            .frame(width: 28, alignment: .trailing)
                    }
                    .frame(maxWidth: 520)
                }

                HStack(spacing: 7) {
                    Image(systemName: "lock.fill")
                    Text("照片与性格数据保存在本机")
                }
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Palette.muted)
                .padding(.top, 8)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(.white.opacity(0.72), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Palette.line, lineWidth: 1))
    }

    private func nameBinding(for profile: CatProfile) -> Binding<String> {
        Binding(
            get: { store.cats.first(where: { $0.id == profile.id })?.name ?? profile.name },
            set: { value in
                guard let index = store.cats.firstIndex(where: { $0.id == profile.id }) else { return }
                var updated = store.cats[index]
                updated.name = value
                store.update(updated)
            }
        )
    }

    private func traitBinding(_ trait: CatTrait, profile: CatProfile) -> Binding<Double> {
        Binding(
            get: { store.cats.first(where: { $0.id == profile.id })?.personality.value(for: trait) ?? 0.5 },
            set: { value in
                guard let index = store.cats.firstIndex(where: { $0.id == profile.id }) else { return }
                var updated = store.cats[index]
                updated.personality.set(value, for: trait)
                store.update(updated)
            }
        )
    }
}
