/*
* Copyright (c) 2020, Nordic Semiconductor
* All rights reserved.
*
* Redistribution and use in source and binary forms, with or without modification,
* are permitted provided that the following conditions are met:
*
* 1. Redistributions of source code must retain the above copyright notice, this
*    list of conditions and the following disclaimer.
*
* 2. Redistributions in binary form must reproduce the above copyright notice, this
*    list of conditions and the following disclaimer in the documentation and/or
*    other materials provided with the distribution.
*
* 3. Neither the name of the copyright holder nor the names of its contributors may
*    be used to endorse or promote products derived from this software without
*    specific prior written permission.
*
* THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
* ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
* WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED.
* IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT,
* INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT
* NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
* PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY,
* WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
* ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
* POSSIBILITY OF SUCH DAMAGE.
*/

import Foundation
import CoreBluetooth

public class CBCentralManagerMock: CBCentralManagerType {
    public var mockDelegate: CBCentralManagerMockDelegate?
    
    public var delegate: CBCentralManagerDelegateType?
    
    /// A list of all mock managers instantiated by user.
    private static var managers: [WeakRef<CBCentralManagerMock>] = []
    
    /// The global state of the Bluetooth adapter on the device.
    internal static var managerState: CBManagerStateType = .poweredOff {
        didSet {
            // For all existing managers...
            managers.forEach { weakRef in
                if let manager = weakRef.ref {
                    // ...stop scanning. If state changed to .poweredOn, scanning
                    // must have been stopped before.
                    if managerState != .poweredOn {
                        manager.stopScan()
                    }
                    // ...and notify delegate.
                    manager.queue.async {
                        manager.delegate?.centralManagerDidUpdateState(manager)
                    }
                }
            }
            // Compact the list, if any of managers were disposed.
            managers.removeAll { $0.ref == nil }
        }
    }
    
    public var state: CBManagerStateType {
        return initialized ? CBCentralManagerMock.managerState : .unknown
    }
    public fileprivate(set) var isScanning: Bool

    private let rssiDeviation = 15 // dBm
    /// The dispatch queue used for all callbacks.
    fileprivate let queue: DispatchQueue
    /// Active timers reporting scan results.
    private var scanTimers: [Timer] = []
    /// A map of peripherals known to this central manager.
    private var peripherals: [UUID : CBPeripheralMock] = [:]
    /// A flag set to true few milliseconds after the manager is created.
    /// Some features, like the state or retrieving peripherals are not
    /// available when manager hasn't been initialized yet.
    private var initialized: Bool = false
    
    public required init() {
        self.isScanning = false
        self.queue = DispatchQueue.main
        initialize()
    }
    
    public required init(delegate: CBCentralManagerDelegateType?,
                         queue: DispatchQueue?) {
        self.isScanning = false
        self.queue = queue ?? DispatchQueue.main
        self.delegate = delegate
        initialize()
    }
    
    public required init(delegate: CBCentralManagerDelegateType?,
                         queue: DispatchQueue?,
                         options: [String : Any]?) {
        self.isScanning = false
        self.queue = queue ?? DispatchQueue.main
        self.delegate = delegate
        initialize()
    }
    
    private func initialize() {
        queue.asyncAfter(deadline: .now() + .milliseconds(10)) { [weak self] in
            if let self = self {
                CBCentralManagerMock.managers.append(WeakRef(self))
                self.initialized = true
                self.delegate?.centralManagerDidUpdateState(self)
            }
        }
    }
    
    /// Turns the Bluetooth adapter on.
    /// The process will take the given amount of time.
    /// - Parameter duration: The transition interval. By default 100 ms.
    public static func powerOn(duration: TimeInterval = 0.1) {
        guard managerState != .poweredOn else {
            return
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + duration) {
            managerState = .poweredOn
        }
    }
    
    /// Turns the Bluetooth adapter off.
    /// The process will take the given amount of time.
    /// - Parameter duration: The transition interval. By default 100 ms.
    public static func powerOff(duration: TimeInterval = 0.1) {
        guard managerState != .poweredOff else {
            return
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + duration) {
            managerState = .poweredOff
        }
    }
    
    /// Sets the initial state of the Bluetooth adapter. This method
    /// should only be called ones, before any `CBCentralManagerMock` is
    /// created. By defult, the initial state is `.poweredOff`.
    /// - Parameter state: The initial state of the Bluetooth adapter.
    public static func setInitialState(_ state: CBManagerStateType) {
        managerState = state
    }
    
    @available(iOS 13.0, *)
    public static func supports(_ features: CBCentralManager.Feature) -> Bool {
        return features.isSubset(of: .extendedScanAndConnect)
    }
    
    /// This is a Timer callback, that's called to emulate scanning for Bluetooth LE
    /// devices. When the `CBCentralManagerScanOptionAllowDuplicatesKey` options
    /// was set when scanning was started, the timer will repeat every advertising
    /// interval until scanning is stopped.
    ///
    /// The scanned peripheral is set as `userInfo`.
    /// - Parameter timer: The timer that is fired.
    @objc private func notify(timer: Timer) {
        guard let scanResult = timer.userInfo as? AdvertisingPeripheral,
              let peripheral = peripherals[scanResult.identifier],
              isScanning else {
            timer.invalidate()
            return
        }
        // Emulate RSSI based on proximity. Apply some deviation.
        let rssi = scanResult.proximity.RSSI
        let deviation = Int.random(in: -rssiDeviation...rssiDeviation)
        delegate?.centralManager(self, didDiscover: peripheral,
                                 advertisementData: scanResult.advertisementData,
                                 rssi: (rssi + deviation) as NSNumber)
        
    }
    
    public func scanForPeripherals(withServices serviceUUIDs: [CBUUID]?,
                                   options: [String : Any]?) {
        guard !isScanning else {
            return
        }
        isScanning = true

        // Obtain list of mock devices.
        if let scannedPeripherals = mockDelegate?.centralManager(self,
                                                                 didStartScanningForPeripheralsWithServices: serviceUUIDs) {
            scannedPeripherals.forEach { device in
                // The central manager has scanned a device. Add it the list of known peripherals.
                if peripherals[device.identifier] == nil {
                    peripherals[device.identifier] = CBPeripheralMock(basedOn: device, scannedBy: self)
                }
                // If no Service UUID was used, or the device matches at least one service,
                // report it to the delegate (call will be delayed using a Timer).
                let services = device.advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]
                if serviceUUIDs == nil ||
                   services?.contains(where: serviceUUIDs!.contains) ?? false {
                    // The timer will be called multiple times if option was set.
                    let allowDuplicates = options?[CBCentralManagerScanOptionAllowDuplicatesKey] as? NSNumber ?? false as NSNumber
                    let timer = Timer.scheduledTimer(timeInterval: device.advertisingInterval,
                                                     target: self,
                                                     selector: #selector(notify(timer:)),
                                                     userInfo: device,
                                                     repeats: allowDuplicates.boolValue)
                    if allowDuplicates.boolValue {
                        scanTimers.append(timer)
                    }
                }
            }
        }
    }
    
    public func stopScan() {
        isScanning = false
        scanTimers.forEach { $0.invalidate() }
        scanTimers.removeAll()
    }
    
    public func connect(_ peripheral: CBPeripheralType, options: [String : Any]?) {
//        if let mock = peripheral as? CBPeripheralMock,
//            mock.state == .disconnected {
//            mock.state = .connecting
//            queue.asyncAfter(deadline: .now() + .milliseconds(30)) {
//                mock.state = .connected
//                self.delegate?.centralManager(self, didConnect: mock)
//            }
//        }
    }
    
    public func cancelPeripheralConnection(_ peripheral: CBPeripheralType) {
//        if let mock = peripheral as? CBPeripheralMock,
//            peripheral.state == .connected || peripheral.state == .connecting {
//            if #available(iOS 9.0, *) {
//                mock.state = .disconnecting
//            }
//            queue.asyncAfter(deadline: .now() + .milliseconds(10)) {
//                mock.state = .disconnected
//                self.delegate?.centralManager(self, didConnect: mock)
//            }
//        }
    }
    
    public func retrievePeripherals(withIdentifiers identifiers: [UUID]) -> [CBPeripheralType] {
        guard state == .poweredOn else {
            // Starting from iOS 13, this method returns peripherals only in ON state.
            return []
        }
        // Get the peripherals already known to this central manager.
        let localPeripherals = peripherals[identifiers]
        // If all were found, return them.
        if localPeripherals.count == identifiers.count {
            return localPeripherals
        }
        let missingIdentifiers = identifiers.filter { peripherals[$0] == nil }
        // Otherwise, we need to look for them among other managers, and
        // copy them to the local manager.
        let peripheralsKnownByOtherManagers = missingIdentifiers
            .flatMap { i in
                CBCentralManagerMock.managers
                    .compactMap { $0.ref?.peripherals[i] }
            }
            .map { CBPeripheralMock(copy: $0, by: self) }
        peripheralsKnownByOtherManagers.forEach {
            peripherals[$0.identifier] = $0
        }
        // Return them in the same order as requested, some may be missing.
        return (localPeripherals + peripheralsKnownByOtherManagers)
            .sorted {
                let firstIndex = identifiers.firstIndex(of: $0.identifier)!
                let secondIndex = identifiers.firstIndex(of: $1.identifier)!
                return firstIndex < secondIndex
            }
    }
    
    public func retrieveConnectedPeripherals(withServices serviceUUIDs: [CBUUID]) -> [CBPeripheralType] {
        guard state == .poweredOn else {
            // Starting from iOS 13, this method returns peripherals only in ON state.
            return []
        }
        // Get the connected peripherals with at least one of the given services
        // that are already known to this central manager.
        let localConnectedPeripherals = peripherals[serviceUUIDs]
            .filter { $0.state == .connected }
        // Other central managers also may know some connected peripherals that
        // are not known to the local one.
        let connectedPeripheralsKnownByOtherManagers = CBCentralManagerMock.managers
            // Get only those managers that were not disposed.
            .filter { $0.ref != nil }
            // Look for connected peripherals known to other managers.
            .flatMap {
                $0.ref!.peripherals[serviceUUIDs]
                    .filter { $0.state == .connected }
            }
            // Search for ones that are not known to the local manager.
            .filter { other in
                !localConnectedPeripherals.contains { local in
                    local.identifier == other.identifier
                }
            }
            // Create a local copy.
            .map { CBPeripheralMock(copy: $0, by: self) }
        // Add those copies to the local manager.
        connectedPeripheralsKnownByOtherManagers.forEach {
            peripherals[$0.identifier] = $0
        }
        return localConnectedPeripherals + connectedPeripheralsKnownByOtherManagers
    }
    
    @available(iOS 13.0, *)
    public func registerForConnectionEvents(options: [CBConnectionEventMatchingOption : Any]?) {
        // Not implemented
    }
    
    public func initiateConnectedPeripheral(name: String? = nil, services: [CBService]) {
        let peripheral = CBPeripheralMock(name: name, services: services, connectedBy: self)
        peripherals[peripheral.identifier] = peripheral
    }
    
}

public class CBPeripheralMock: CBPeer, CBPeripheralType {
    public var delegate: CBPeripheralDelegateType?
    
    private let queue: DispatchQueue
    private let _identifier: UUID
    
    public override var identifier: UUID {
        return _identifier
    }
    
    public internal(set) var name: String?
    public internal(set) var state: CBPeripheralState = .disconnected
    public internal(set) var services: [CBService]? = nil
    public internal(set) var canSendWriteWithoutResponse: Bool = false
    public internal(set) var ancsAuthorized: Bool = false
    
    fileprivate init(basedOn peripheral: AdvertisingPeripheral, scannedBy central: CBCentralManagerMock) {
        self._identifier = peripheral.identifier
        self.name = peripheral.advertisementData[CBAdvertisementDataLocalNameKey] as? String
        self.queue = central.queue
    }
    
    fileprivate init(name: String?, services: [CBService],
                     connectedBy central: CBCentralManagerMock) {
        self._identifier = UUID()
        self.name = name
        self.queue = central.queue
        
        // Emulate a connected device.
        self.state = .connected
        self.services = services
        self.canSendWriteWithoutResponse = true
    }
    
    fileprivate init(copy: CBPeripheralMock, by central: CBCentralManagerMock) {
        self._identifier = copy._identifier
        self.name = copy.name
        self.queue = central.queue
        
        // State is not copied from manager to manager.
        self.state = .disconnected
        self.services = nil
        self.canSendWriteWithoutResponse = false
    }
        
    private var _delegate: CBPeripheralDelegateType?
    
    public func discoverServices(_ serviceUUIDs: [CBUUID]?) {
//        if serviceUUIDs?.contains(BlinkyPeripheral.nordicBlinkyServiceUUID) ?? true {
//            queue.asyncAfter(deadline: .now() + .milliseconds(40)) {
//                self.delegate?.peripheral(self, didDiscoverServices: nil)
//            }
//        }
    }
    
    public func discoverCharacteristics(_ characteristicUUIDs: [CBUUID]?, for service: CBService) {
//        if service == BlinkyPeripheral.nordicBlinkyServiceUUID {
//            queue.asyncAfter(deadline: .now() + .milliseconds(40)) {
//                self.delegate?.peripheral(self, didDiscoverCharacteristicsFor: service, error: nil)
//            }
//        }
    }
    
    public func discoverDescriptors(for characteristic: CBCharacteristic) {
        // TODO
    }
    
    public func readValue(for characteristic: CBCharacteristic) {
//        if characteristic.uuid == BlinkyPeripheral.ledCharacteristicUUID {
//            queue.asyncAfter(deadline: .now() + .milliseconds(40)) {
//                self.delegate?.peripheral(self, didUpdateValueFor: characteristic, error: nil)
//            }
//        }
    }
    
    public func readValue(for descriptor: CBDescriptor) {
        // TODO
    }
    
    public func maximumWriteValueLength(for type: CBCharacteristicWriteType) -> Int {
        // TODO
        return 0
    }
    
    public func writeValue(_ data: Data, for characteristic: CBCharacteristic, type: CBCharacteristicWriteType) {
        // TODO
    }
    
    public func writeValue(_ data: Data, for descriptor: CBDescriptor) {
        // TODO
    }
    
    public func setNotifyValue(_ enabled: Bool, for characteristic: CBCharacteristic) {
        // TODO
    }
    
    public func openL2CAPChannel(_ PSM: CBL2CAPPSM) {
        // TODO
    }
    
    public override var hash: Int {
        return _identifier.hashValue
    }
}

private class WeakRef<T: AnyObject> {
    fileprivate private(set) weak var ref: T?
    
    fileprivate init(_ value: T) {
        self.ref = value
    }
}

private extension Dictionary where Key == UUID, Value == CBPeripheralMock {
    
    subscript(identifiers: [UUID]) -> [CBPeripheralMock] {
        return identifiers.compactMap { self[$0] }
    }
    
    subscript(serviceUUIDs: [CBUUID]) -> [CBPeripheralMock] {
        return filter { (_, peripheral) in
            peripheral.services?
                .contains(where: { service in
                    serviceUUIDs.contains(service.uuid)
                })
            ?? false
        }.map { $0.value }
    }
    
}
