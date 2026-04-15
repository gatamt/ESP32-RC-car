//
//  GATA_RC_P4App.swift
//  GATA_RC_P4
//
//  Main application entry point for ESP32-P4 FireBeetle controller
//

import SwiftUI
import Combine
import GameController
import Network
import UIKit

@main
struct GATA_RC_P4App: App {
    var body: some Scene {
        WindowGroup {
            RootEntryView()
                .preferredColorScheme(.dark)
                .onReceive(NotificationCenter.default.publisher(for: .exitDrivingUIRequested)) { _ in
                    SharedAppState.shared.controlsActive = false
                    SharedAppState.shared.model.controlsEnabled = false
                    RootEntryView.forceBackToMenu()
                }
        }
    }
}

// MARK: - Shared App State

/// Singleton holder for shared state between menu and main UI
final class SharedAppState: ObservableObject {
    static let shared = SharedAppState()

    let model: AppModel
    let netHolder: NetHolder

    /// Controls whether the car can be driven (only true in ContentView)
    @Published var controlsActive: Bool = false

    private init() {
        self.model = AppModel()
        self.netHolder = NetHolder()
    }

    /// Initialize network if needed (safe to call multiple times)
    func ensureNetworkReady() {
        netHolder.initIfNeeded(model: model)
    }
}

// MARK: - WiFi Monitor

/// Monitors WiFi connectivity and triggers reconnection when network changes
final class WiFiConnectionMonitor: ObservableObject {
    private var pathMonitor: NWPathMonitor?
    private let monitorQueue = DispatchQueue(label: "wifi.monitor.queue")

    @Published var isOnWiFi: Bool = false
    @Published var networkChangeCount: Int = 0

    private var lastPath: NWPath?

    init() {
        startMonitoring()
    }

    deinit {
        stopMonitoring()
    }

    func startMonitoring() {
        pathMonitor?.cancel()
        pathMonitor = NWPathMonitor(requiredInterfaceType: .wifi)
        pathMonitor?.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                let wasOnWiFi = self?.isOnWiFi ?? false
                let nowOnWiFi = path.status == .satisfied
                self?.isOnWiFi = nowOnWiFi

                // Detect network change (WiFi reconnect or switch)
                if nowOnWiFi && (!wasOnWiFi || self?.didNetworkChange(path) == true) {
                    self?.networkChangeCount += 1
                }
                self?.lastPath = path
            }
        }
        pathMonitor?.start(queue: monitorQueue)
    }

    func stopMonitoring() {
        pathMonitor?.cancel()
        pathMonitor = nil
    }

    private func didNetworkChange(_ newPath: NWPath) -> Bool {
        guard let oldPath = lastPath else { return true }
        // Check if available interfaces changed
        return oldPath.availableInterfaces != newPath.availableInterfaces
    }
}

// MARK: - Root Entry

/// Root view that shows the new start screen before the classic driving UI.
private struct RootEntryView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var sharedState = SharedAppState.shared
    @StateObject private var wifiMonitor = WiFiConnectionMonitor()
    @StateObject private var menuState: StartMenuState
    @State private var showMainUI = false
    @State private var inputController: StartMenuInputManager?

    init() {
        // Use shared model for menu state
        _menuState = StateObject(wrappedValue: StartMenuState(model: SharedAppState.shared.model))
    }
    
    static func forceBackToMenu() {
        SharedAppState.shared.controlsActive = false
        SharedAppState.shared.model.controlsEnabled = false
        NotificationCenter.default.post(name: .forceMenuReset, object: nil)
    }

    var body: some View {
        ZStack {
            if showMainUI {
                ContentView()
                    .environmentObject(sharedState)
            } else {
                StartMenuView(state: menuState)
            }
        }
        .onAppear {
            if inputController == nil {
                inputController = StartMenuInputManager(state: menuState)
            }
            // Ensure controls are disabled in menu
            sharedState.controlsActive = false
            sharedState.ensureNetworkReady()
        }
        .onChange(of: menuState.shouldLaunchMainUI) { launch in
            if launch {
                inputController?.stop()
                // Don't shutdown network - keep the established connection!
                showMainUI = true
            }
        }
        .onChange(of: scenePhase) { phase in
            if phase == .active {
                // Always ensure network is ready when app becomes active
                sharedState.ensureNetworkReady()
                // Trigger a reconnect attempt on all network managers
                sharedState.netHolder.triggerReconnect()
            }
        }
        .onChange(of: wifiMonitor.networkChangeCount) { _ in
            // WiFi network changed - trigger reconnect on all managers
            if wifiMonitor.isOnWiFi {
                sharedState.netHolder.triggerReconnect()
            }
        }
        .onChange(of: menuState.screen) { screen in
            // When entering "Add New Car", trigger reconnect
            if !showMainUI && screen == .addNewCar {
                sharedState.netHolder.triggerReconnect()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .forceMenuReset)) { _ in
            showMainUI = false
            // Reset menu to YOUR CARS screen and restart controller input
            menuState.resetToYourCars()
            inputController?.start()
        }
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let exitDrivingUIRequested = Notification.Name("exitDrivingUIRequested")
    static let forceMenuReset = Notification.Name("forceMenuReset")
}
// MARK: - Start Menu State

/// Navigation and state model for the start screen.
final class StartMenuState: ObservableObject {
    enum Screen {
        case mainMenu
        case yourCars
        case addNewCar
        case nameCar
    }
    
    enum MainSelection: CaseIterable {
        case yourCars
        case addNewCar
    }
    
    enum Direction {
        case up, down, left, right
    }
    
    @Published var screen: Screen = .mainMenu
    @Published var mainSelection: MainSelection = .yourCars
    @Published var savedCars: [SavedCar]
    @Published var selectedCarIndex: Int?
    @Published var shouldLaunchMainUI = false
    @Published var carConnected = false
    private var lastConnectedAt: Date?
    @Published var carNameDraft: String = ""
    @Published var showDeletePrompt = false
    @Published var deleteSelection: DeleteSelection = .no
    @Published var showConnectionBlocker = false
    
    enum DeleteSelection {
        case no, yes
    }
    
    let model: AppModel
    private var cancellables: Set<AnyCancellable> = []
    private var connectionCheckTimer: Timer?

    private let store = SavedCarsStore()

    init(model: AppModel) {
        self.model = model
        self.savedCars = store.load()
        self.selectedCarIndex = savedCars.isEmpty ? nil : 0
        observeConnection()
        startConnectionCheckTimer()
    }

    deinit {
        connectionCheckTimer?.invalidate()
    }
    
    func moveSelection(_ direction: Direction) {
        switch screen {
        case .mainMenu:
            guard !showDeletePrompt else { return }
            guard direction == .up || direction == .down else { return }
            let options = MainSelection.allCases
            guard let currentIndex = options.firstIndex(of: mainSelection) else { return }
            let delta = direction == .up ? -1 : 1
            let nextIndex = max(0, min(options.count - 1, currentIndex + delta))
            mainSelection = options[nextIndex]
        case .yourCars:
            if showDeletePrompt {
                // Left/Right toggles delete selection
                if direction == .left || direction == .right {
                    deleteSelection = (deleteSelection == .no) ? .yes : .no
                }
            } else {
                guard direction == .up || direction == .down else { return }
                guard !savedCars.isEmpty else { return }
                guard let current = selectedCarIndex else { selectedCarIndex = 0; return }
                let delta = direction == .up ? -1 : 1
                let next = max(0, min(savedCars.count - 1, current + delta))
                selectedCarIndex = next
            }
        case .addNewCar:
            break
        case .nameCar:
            break
        }
    }
    
    func activateSelection() {
        switch screen {
        case .mainMenu:
            guard !showDeletePrompt else { return }
            switch mainSelection {
            case .yourCars:
                screen = .yourCars
                selectedCarIndex = savedCars.isEmpty ? nil : 0
            case .addNewCar:
                screen = .addNewCar
            }
        case .yourCars:
            if showDeletePrompt {
                if deleteSelection == .yes { deleteSelectedCar() }
                else { cancelDeletePrompt() }
            } else if showConnectionBlocker {
                showConnectionBlocker = false
            } else {
                guard !savedCars.isEmpty else { return }
                if !carConnected {
                    showConnectionBlocker = true
                } else {
                    if let idx = selectedCarIndex, savedCars.indices.contains(idx) {
                        model.activeCarName = savedCars[idx].name
                    }
                    shouldLaunchMainUI = true
                }
            }
        case .addNewCar:
            if carConnected {
                screen = .nameCar
            }
        case .nameCar:
            break
        }
    }
    
    func goBack() {
        switch screen {
        case .mainMenu:
            break
        case .yourCars:
            if showDeletePrompt { cancelDeletePrompt() }
            else if showConnectionBlocker { showConnectionBlocker = false }
            else { screen = .mainMenu }
        case .addNewCar:
            screen = .mainMenu
        case .nameCar:
            screen = .addNewCar
        }
    }
    
    func requestDeletePrompt() {
        guard screen == .yourCars, !savedCars.isEmpty else { return }
        showDeletePrompt = true
        deleteSelection = .no
    }
    
    func cancelDeletePrompt() {
        showDeletePrompt = false
    }
    
    func deleteSelectedCar() {
        guard screen == .yourCars, let idx = selectedCarIndex, savedCars.indices.contains(idx) else { return }
        savedCars.remove(at: idx)
        store.save(savedCars)
        if savedCars.isEmpty { selectedCarIndex = nil }
        else { selectedCarIndex = min(idx, savedCars.count - 1) }
        showDeletePrompt = false
    }
    
    func saveCarAndContinue() {
        let trimmed = carNameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        dismissKeyboard()
        let newCar = SavedCar(name: trimmed, mode: nil)
        savedCars.append(newCar)
        store.save(savedCars)
        selectedCarIndex = savedCars.count - 1
        model.activeCarName = newCar.name
        shouldLaunchMainUI = true
    }

    /// Resets menu state to YOUR CARS screen (used when returning from driving UI)
    func resetToYourCars() {
        screen = .yourCars
        selectedCarIndex = savedCars.isEmpty ? nil : 0
        shouldLaunchMainUI = false
        showDeletePrompt = false
        showConnectionBlocker = false
        carNameDraft = ""
    }
    
    private func observeConnection() {
        // Primary: Combine-based observation
        Publishers.CombineLatest(model.$bleConnected, model.$teleAlive)
            .map { $0 || $1 }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] connected in
                self?.updateConnectionState(connected: connected)
            }
            .store(in: &cancellables)
    }

    /// Backup timer that polls connection state every 0.5 seconds
    /// This ensures UI updates even if Combine publishers miss events
    private func startConnectionCheckTimer() {
        connectionCheckTimer?.invalidate()
        connectionCheckTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            let connected = self.model.bleConnected || self.model.teleAlive
            self.updateConnectionState(connected: connected)
        }
    }

    private func updateConnectionState(connected: Bool) {
        let now = Date()
        if connected {
            lastConnectedAt = now
            if !carConnected {
                carConnected = true
            }
        } else {
            if let last = lastConnectedAt, now.timeIntervalSince(last) < 2.5 {
                // Grace period - keep showing connected
                if !carConnected {
                    carConnected = true
                }
            } else {
                if carConnected {
                    carConnected = false
                }
            }
        }
    }
}

// MARK: - Helpers

private func dismissKeyboard() {
    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
}

// MARK: - Controller Input Manager

/// Polls the PS5 controller's D-pad + X/O for menu navigation.
final class StartMenuInputManager {
    private weak var state: StartMenuState?
    private var timer: Timer?
    
    private var lastUp = false
    private var lastDown = false
    private var lastLeft = false
    private var lastRight = false
    private var lastCross = false
    private var lastCircle = false
    private var lastTriangle = false
    
    init(state: StartMenuState) {
        self.state = state
        start()
    }
    
    deinit {
        stop()
    }
    
    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func start() {
        // Prevent duplicate timers
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 45.0, repeats: true) { [weak self] _ in
            self?.poll()
        }
    }
    
    private func poll() {
        guard let pad = GCController.controllers().first?.extendedGamepad,
              let state = state else { return }
        
        let up = pad.dpad.up.isPressed
        let down = pad.dpad.down.isPressed
        let left = pad.dpad.left.isPressed
        let right = pad.dpad.right.isPressed
        let cross = pad.buttonA.isPressed  // PS5: X
        let circle = pad.buttonB.isPressed // PS5: O
        let triangle = pad.buttonY.isPressed // PS5: △
        
        if up && !lastUp { state.moveSelection(.up) }
        if down && !lastDown { state.moveSelection(.down) }
        if left && !lastLeft { state.moveSelection(.left) }
        if right && !lastRight { state.moveSelection(.right) }
        if cross && !lastCross { state.activateSelection() }
        if circle && !lastCircle { state.goBack() }
        if triangle && !lastTriangle { state.requestDeletePrompt() }
        
        lastUp = up
        lastDown = down
        lastLeft = left
        lastRight = right
        lastCross = cross
        lastCircle = circle
        lastTriangle = triangle
    }
}

// MARK: - Models

/// Saved car (placeholder for future functionality).
struct SavedCar: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var mode: String?
    
    init(id: UUID = UUID(), name: String, mode: String? = nil) {
        self.id = id
        self.name = name
        self.mode = mode
    }
}

/// Loads saved cars from UserDefaults (writes come later).
struct SavedCarsStore {
    private let key = "savedCarsList"
    
    func load() -> [SavedCar] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([SavedCar].self, from: data)) ?? []
    }
    
    func save(_ cars: [SavedCar]) {
        if let data = try? JSONEncoder().encode(cars) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}

// MARK: - Views

/// Hosts the different screens of the start menu.
private struct StartMenuView: View {
    @ObservedObject var state: StartMenuState
    
    var body: some View {
        GeometryReader { geo in
            ZStack {
                StartMenuBackground()
                
            switch state.screen {
            case .mainMenu:
                MainMenuView(state: state, size: geo.size)
            case .yourCars:
                YourCarsView(state: state, size: geo.size)
            case .addNewCar:
                AddNewCarView(state: state, size: geo.size)
            case .nameCar:
                NameCarView(state: state, size: geo.size)
            }
        }
    }
}
}

/// Main menu of the start screen.
private struct MainMenuView: View {
    @ObservedObject var state: StartMenuState
    let size: CGSize
    
    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            LegendColumn()
                .frame(width: min(230, size.width * 0.28), alignment: .leading)
                .padding(.leading, 6)
            
            VStack(spacing: 32) {
                Spacer(minLength: 10)
                VStack(spacing: 16) {
                    MenuBlock(
                        title: "YOUR CARS",
                        isSelected: state.mainSelection == .yourCars,
                        width: menuWidth,
                        height: 110
                    )
                    MenuBlock(
                        title: "ADD NEW CAR",
                        isSelected: state.mainSelection == .addNewCar,
                        width: menuWidth,
                        height: 110
                    )
                }
                .padding(.horizontal, 12)
                
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.leading, -26)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    private var menuWidth: CGFloat {
        max(340, size.width * 0.50)
    }
}

/// List of saved cars.
private struct YourCarsView: View {
    @ObservedObject var state: StartMenuState
    let size: CGSize
    
    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Text("YOUR CARS")
                    .cyberFont(16, anchor: .leading)
                    .foregroundColor(.white)
                Spacer()
            }
            .padding(.horizontal, 32)
            .padding(.top, 28)
            
            Spacer()
            
            if state.savedCars.isEmpty {
                VStack(spacing: 10) {
                    Text("No saved cars...")
                        .cyberFont(14, anchor: .center)
                        .foregroundColor(.white.opacity(0.65))
                        .multilineTextAlignment(.center)
                    HStack(alignment: .center, spacing: 18) {
                        Text("Press")
                            .cyberFont(13, anchor: .center)
                            .foregroundColor(.white.opacity(0.55))
                        PSButtonO()
                            .frame(width: 18, height: 18)
                        Spacer().frame(width: 54)
                        Text("to return and choose \"ADD NEW CAR\" to save your first car.")
                            .cyberFont(13, anchor: .center)
                            .foregroundColor(.white.opacity(0.55))
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                    }
                    .frame(maxWidth: 560, alignment: .center)
                    .padding(.leading, -80)
                }
                .padding()
                .frame(maxWidth: 560)
            } else {
                VStack(spacing: 12) {
                    ForEach(Array(state.savedCars.enumerated()), id: \.element.id) { idx, car in
                        CarRow(
                            car: car,
                            isSelected: state.selectedCarIndex == idx,
                            width: listWidth
                        )
                    }
                }
            }
            
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 12)
        .overlay(alignment: .leading) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    PSButtonTriangle()
                        .frame(width: 32, height: 32)
                    Text("→ DELETE CAR")
                        .cyberFont(12, anchor: .leading)
                        .foregroundColor(.white.opacity(0.6))
                }
                Spacer()
            }
            .padding(.leading, 8)
            .padding(.top, 64)
        }
        .overlay {
            if state.showDeletePrompt {
                DeletePrompt(state: state)
            }
            if state.showConnectionBlocker {
                ConnectionBlocker(state: state)
            }
        }
    }
    
    private var listWidth: CGFloat {
        min(size.width * 0.6, 520)
    }
}

/// Placeholder while "Add New Car" is not yet implemented.
private struct AddNewCarView: View {
    @ObservedObject var state: StartMenuState
    let size: CGSize
    
    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            if state.carConnected {
                Text("Car connected!")
                    .cyberFont(18, anchor: .center)
                    .foregroundColor(.white)
                
                HStack(spacing: 18) {
                    Text("Press")
                        .cyberFont(13, anchor: .center)
                        .foregroundColor(.white.opacity(0.65))
                    PSButtonX()
                        .frame(width: 18, height: 18)
                    Spacer().frame(width: 20)
                    Text("to name your car.")
                        .cyberFont(13, anchor: .center)
                        .foregroundColor(.white.opacity(0.55))
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                }
                .frame(maxWidth: 560, alignment: .center)
                .padding(.leading, -80)
            } else {
                Text("Go to Settings → WiFi → and connect to the receiver’s WiFi (GATA_RC).")
                    .cyberFont(14, anchor: .center)
                    .foregroundColor(.white.opacity(0.7))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 600)
                    .padding(.horizontal, 20)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Name Car View

private struct NameCarView: View {
    @ObservedObject var state: StartMenuState
    let size: CGSize
    @FocusState private var nameFieldFocused: Bool
    
    var body: some View {
        VStack(spacing: 18) {
            Spacer().frame(height: 10)
            
            Text("NAME YOUR CAR")
                .cyberFont(18, anchor: .center)
                .foregroundColor(.white)
                .padding(.bottom, 8)
            
            HStack(alignment: .center, spacing: 14) {
                // Name entry block
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.white.opacity(0.25), lineWidth: 1)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color.black.opacity(0.35))
                    )
                    .frame(width: entryWidth, height: 70)
                    .overlay(
                        TextField("Enter car name", text: $state.carNameDraft)
                            .focused($nameFieldFocused)
                            .textInputAutocapitalization(.words)
                            .disableAutocorrection(true)
                            .keyboardType(.default)
                            .foregroundColor(.white)
                            .tint(HUDColors.blue)
                            .padding(.horizontal, 16)
                    )
                
                // Save button block
                Button {
                    state.saveCarAndContinue()
                } label: {
                    MenuBlock(
                        title: "SAVE",
                        isSelected: false,
                        width: 140,
                        height: 70
                    )
                }
                .buttonStyle(.plain)
            }
            .padding(.leading, -40) // shift row slightly left; net effect moves right vs before
            
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 20)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                nameFieldFocused = true
            }
        }
    }
    
    private var entryWidth: CGFloat {
        min(size.width * 0.65, 520)
    }
}

// MARK: - Components

/// Cyber-styled menu block.
private struct MenuBlock: View {
    let title: String
    let isSelected: Bool
    let width: CGFloat
    let height: CGFloat
    
    var body: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(isSelected ? HUDColors.blue.opacity(0.35) : Color.black.opacity(0.5))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(isSelected ? HUDColors.blue : Color.white.opacity(0.2), lineWidth: isSelected ? 3 : 1)
            )
            .shadow(color: HUDColors.blue.opacity(isSelected ? 0.55 : 0.2), radius: isSelected ? 12 : 6, y: 4)
            .frame(width: width, height: height)
        .overlay(
            Text(title)
                .cyberFont(22, anchor: .center)
                .foregroundColor(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        )
    }
}

/// Single car row.
private struct CarRow: View {
    let car: SavedCar
    let isSelected: Bool
    let width: CGFloat
    
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(car.name)
                    .cyberFont(16, anchor: .leading)
                    .foregroundColor(.white)
                if let mode = car.mode {
                    Text(mode.uppercased())
                        .cyberFont(10, anchor: .leading)
                        .foregroundColor(HUDColors.blue.opacity(0.8))
                }
            }
            Spacer()
            if isSelected {
                Text("X")
                    .cyberFont(12, anchor: .trailing)
                    .foregroundColor(.white.opacity(0.8))
                    .padding(.trailing, 6)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(isSelected ? HUDColors.blue.opacity(0.32) : Color.black.opacity(0.45))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(isSelected ? HUDColors.blue : Color.white.opacity(0.16), lineWidth: isSelected ? 2 : 1)
                )
        )
        .frame(width: width)
        .animation(.easeInOut(duration: 0.1), value: isSelected)
    }
}

/// Background with a subtle gradient.
private struct StartMenuBackground: View {
    var body: some View {
        LinearGradient(
            colors: [
                Color.black.opacity(0.95),
                Color(red: 0.02, green: 0.05, blue: 0.16)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .overlay(
            RadialGradient(
                gradient: Gradient(colors: [HUDColors.blue.opacity(0.12), .clear]),
                center: .center,
                startRadius: 60,
                endRadius: 420
            )
        )
        .ignoresSafeArea()
    }
}

// MARK: - Delete Prompt

private struct DeletePrompt: View {
    @ObservedObject var state: StartMenuState
    
    var body: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()
            
            VStack(spacing: 16) {
                Text("Are you sure you want to delete this car?")
                    .cyberFont(14, anchor: .center)
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 12)
                
                HStack(spacing: 14) {
                    Button {
                        state.cancelDeletePrompt()
                    } label: {
                        MenuBlock(title: "No", isSelected: state.deleteSelection == .no, width: 120, height: 60)
                    }
                    .buttonStyle(.plain)
                    
                    Button {
                        state.deleteSelectedCar()
                    } label: {
                        MenuBlock(title: "Yes", isSelected: state.deleteSelection == .yes, width: 120, height: 60)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(28)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.black.opacity(0.45))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(Color.white.opacity(0.22), lineWidth: 1)
                    )
            )
            .frame(maxWidth: 520)
            .padding(.horizontal, 28)
        }
    }
}

/// Blocker shown when trying to enter a car without connection.
private struct ConnectionBlocker: View {
    @ObservedObject var state: StartMenuState
    
    var body: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()
            
            VStack(spacing: 16) {
                Text("Car not connected")
                    .cyberFont(14, anchor: .center)
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 12)
                
                Text("Press O to close")
                    .cyberFont(12, anchor: .center)
                    .foregroundColor(.white.opacity(0.7))
            }
            .padding(28)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.black.opacity(0.45))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(Color.white.opacity(0.22), lineWidth: 1)
                    )
            )
            .frame(maxWidth: 520)
            .padding(.horizontal, 28)
        }
    }
}

// MARK: - Legends

/// Left column with X/O legend and D-pad graphic.
private struct LegendColumn: View {
    private let infoColor = Color.white.opacity(0.6)
    
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                PSButtonX()
                    .frame(width: 32, height: 32)
                    .padding(.leading, 14)
                Text("→ ENTER")
                    .cyberFont(12, anchor: .leading)
                    .foregroundColor(infoColor)
            }
            HStack(spacing: 8) {
                PSButtonO()
                    .frame(width: 32, height: 32)
                    .padding(.leading, 14)
                Text("→ RETURN")
                    .cyberFont(12, anchor: .leading)
                    .foregroundColor(infoColor)
            }
            
            Spacer().frame(height: 4)
            
            HStack(alignment: .center, spacing: 8) {
                DPadIcon()
                    .frame(width: 78, height: 78)
                    .padding(.leading, -6)
                Text("→ NAVIGATE")
                    .cyberFont(12, anchor: .leading)
                    .foregroundColor(infoColor)
            }
            
            Spacer()
        }
        .padding(.top, 78)
    }
}

/// Stylized PS5 X button.
private struct PSButtonX: View {
    private let outer = Color(red: 0.0, green: 0.45, blue: 0.9)
    private let inner = Color(red: 0.35, green: 0.95, blue: 1.0)
    
    var body: some View {
        ZStack {
            XShape()
                .stroke(outer, lineWidth: 5)
            XShape()
                .stroke(inner, lineWidth: 2)
        }
    }
}

/// Stylized PS5 Triangle button.
private struct PSButtonTriangle: View {
    private let outer = Color(red: 0.0, green: 0.45, blue: 0.0)
    private let inner = Color(red: 0.1, green: 0.9, blue: 0.2)
    
    var body: some View {
        ZStack {
            TriangleShape()
                .stroke(outer, lineWidth: 5)
            TriangleShape()
                .stroke(inner, lineWidth: 2)
        }
    }
}

/// Stylized PS5 O button.
private struct PSButtonO: View {
    private let outer = Color(red: 0.75, green: 0.0, blue: 0.0)
    private let inner = Color(red: 0.95, green: 0.25, blue: 0.25)
    
    var body: some View {
        ZStack {
            Circle()
                .stroke(outer, lineWidth: 5)
            Circle()
                .stroke(inner, lineWidth: 2)
        }
    }
}

private struct XShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let inset: CGFloat = rect.width * 0.18
        p.move(to: CGPoint(x: inset, y: inset))
        p.addLine(to: CGPoint(x: rect.maxX - inset, y: rect.maxY - inset))
        p.move(to: CGPoint(x: rect.maxX - inset, y: inset))
        p.addLine(to: CGPoint(x: inset, y: rect.maxY - inset))
        return p.strokedPath(StrokeStyle(lineWidth: 1, lineCap: .round))
    }
}

private struct TriangleShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let top = CGPoint(x: rect.midX, y: rect.minY + rect.height * 0.12)
        let left = CGPoint(x: rect.minX + rect.width * 0.12, y: rect.maxY - rect.height * 0.12)
        let right = CGPoint(x: rect.maxX - rect.width * 0.12, y: rect.maxY - rect.height * 0.12)
        p.move(to: top)
        p.addLine(to: right)
        p.addLine(to: left)
        p.closeSubpath()
        return p
    }
}

/// D-pad icon inspired by the reference image.
private struct DPadIcon: View {
    var body: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)
            let thickness = size * 0.34
            let radius = size * 0.16
            let arrowSize = size * 0.18
            let triInset = arrowSize * 0.6
            
            ZStack {
                // Cross shape
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .frame(width: thickness, height: size)
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .frame(width: size, height: thickness)
            }
            .foregroundColor(.black)
            .overlay {
                // Arrows
                ArrowTriangle()
                    .fill(Color.white)
                    .frame(width: arrowSize, height: arrowSize)
                    .position(x: size / 2, y: triInset)
                
                ArrowTriangle()
                    .rotation(Angle(degrees: 180))
                    .fill(Color.white)
                    .frame(width: arrowSize, height: arrowSize)
                    .position(x: size / 2, y: size - triInset)
                
                ArrowTriangle()
                    .rotation(Angle(degrees: -90))
                    .fill(Color.white)
                    .frame(width: arrowSize, height: arrowSize)
                    .position(x: triInset, y: size / 2)
                
                ArrowTriangle()
                    .rotation(Angle(degrees: 90))
                    .fill(Color.white)
                    .frame(width: arrowSize, height: arrowSize)
                    .position(x: size - triInset, y: size / 2)
            }
        }
    }
}

/// Small triangle used for D-pad arrow cutouts.
private struct ArrowTriangle: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.midX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}
