import Foundation
import os
import os.log
import StoreKit

/// The one purchase RCam sells: a non-consumable that turns the watermark off.
///
/// StoreKit 2 is the source of truth. `currentEntitlements` is read at launch
/// and after every purchase or restore, and `Transaction.updates` is watched
/// for the life of the process so a refund, a revoked Family Sharing purchase,
/// or a purchase completed elsewhere flips the state without a relaunch. Both
/// come from StoreKit's local cache of signed transactions, so a Mac with no
/// network still unlocks.
///
/// The answer is mirrored into `UserDefaults` for one reason only: the frames
/// pushed in the first moments after launch should use the last known answer
/// rather than wait for the StoreKit query, or every paying user would see the
/// watermark flash on every launch. StoreKit overwrites the cached value as
/// soon as it answers, so forging the flag buys a second of clean video per
/// launch and nothing more. A fresh install, and an unreachable App Store on a
/// fresh install, both mean locked.
///
/// `shouldWatermark` is read on the decode thread for every frame, hence the
/// lock rather than the `@Published` mirror the UI observes.
final class Store: ObservableObject {
    static let unlockProductID = "com.strawdynamics.rcam.unlock"
    private static let cacheKey = "isUnlocked"

    enum ProductState {
        case loading
        case loaded(Product)
        case failed(String)
    }

    enum PurchaseState: Equatable {
        case idle
        case inProgress
        /// Ask to Buy: the purchase is waiting on a parent or guardian. The
        /// transaction arrives through `Transaction.updates` when approved.
        case pending
        case failed(String)
    }

    @Published private(set) var isUnlocked: Bool
    @Published private(set) var productState: ProductState = .loading
    @Published private(set) var purchaseState: PurchaseState = .idle
    /// True while the Debug `forceLocked` override is keeping the watermark on
    /// despite a purchase. Surfaced in Settings so the override is never
    /// mistaken for a broken unlock. Always false in Release.
    @Published private(set) var forceLockedActive = Store.forceLocked

    private let watermarkFlag: OSAllocatedUnfairLock<Bool>
    private var updatesTask: Task<Void, Never>?
    private let log = Logger(subsystem: "com.strawdynamics.rcam", category: "Store")

    /// Frame-path read: true while the watermark should be drawn.
    var shouldWatermark: Bool { watermarkFlag.withLock { $0 } }

    init() {
        let cached = UserDefaults.standard.bool(forKey: Self.cacheKey)
        isUnlocked = cached
        watermarkFlag = OSAllocatedUnfairLock(initialState: !cached || Self.forceLocked)
    }

    deinit {
        updatesTask?.cancel()
    }

    func start() {
        updatesTask = Task.detached { [weak self] in
            for await result in Transaction.updates {
                guard let self else { return }
                if case .verified(let transaction) = result {
                    self.log.info("transaction update: \(transaction.productID, privacy: .public) revoked=\(transaction.revocationDate != nil)")
                    await transaction.finish()
                }
                await self.refreshEntitlements()
            }
        }
        Task { [weak self] in
            await self?.refreshEntitlements()
            await self?.loadProduct()
        }
    }

    /// Re-derive the unlock from StoreKit and publish it.
    func refreshEntitlements() async {
        var unlocked = false
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result else { continue }
            if transaction.productID == Self.unlockProductID, transaction.revocationDate == nil {
                unlocked = true
            }
        }
        await setUnlocked(unlocked)
    }

    @MainActor
    private func setUnlocked(_ unlocked: Bool) {
        if unlocked != isUnlocked {
            log.info("unlock state → \(unlocked)")
        }
        isUnlocked = unlocked
        UserDefaults.standard.set(unlocked, forKey: Self.cacheKey)
        let forced = Self.forceLocked
        if forced {
            log.info("forceLocked is set — watermark stays on regardless of purchase")
        }
        forceLockedActive = forced
        watermarkFlag.withLock { $0 = !unlocked || forced }
    }

    func loadProduct() async {
        await MainActor.run { productState = .loading }
        do {
            let products = try await Product.products(for: [Self.unlockProductID])
            log.info("product request returned \(products.count) product(s)")
            await MainActor.run {
                if let product = products.first {
                    log.info("product loaded: \(product.displayName, privacy: .public) \(product.displayPrice, privacy: .public)")
                    productState = .loaded(product)
                } else {
                    // The request succeeded but App Store Connect has no such
                    // product -- the record is missing or not yet ready.
                    productState = .failed("The App Store returned no product.")
                }
            }
        } catch {
            log.error("product load failed: \(error.localizedDescription, privacy: .public)")
            await MainActor.run { productState = .failed(error.localizedDescription) }
        }
    }

    @MainActor
    func purchase() async {
        guard case .loaded(let product) = productState else { return }
        purchaseState = .inProgress
        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                guard case .verified(let transaction) = verification else {
                    purchaseState = .failed("The App Store receipt could not be verified.")
                    return
                }
                await transaction.finish()
                await refreshEntitlements()
                purchaseState = .idle
            case .userCancelled:
                purchaseState = .idle
            case .pending:
                purchaseState = .pending
            @unknown default:
                purchaseState = .idle
            }
        } catch {
            log.error("purchase failed: \(error.localizedDescription, privacy: .public)")
            purchaseState = .failed(error.localizedDescription)
        }
    }

    /// "Restore Purchases": force a sync with the signed-in Apple Account, then
    /// re-read entitlements. Required for non-consumables by App Review 3.1.1.
    @MainActor
    func restore() async {
        purchaseState = .inProgress
        do {
            try await AppStore.sync()
            await refreshEntitlements()
            purchaseState = isUnlocked ? .idle : .failed("No RCam purchase was found for this Apple Account.")
        } catch {
            log.error("restore failed: \(error.localizedDescription, privacy: .public)")
            purchaseState = .failed(error.localizedDescription)
        }
    }

    /// Debug-only: `defaults write com.strawdynamics.rcam forceLocked -bool YES`
    /// keeps the watermark on for a purchased (sandbox) account, so its
    /// placement and weight can be iterated without touching StoreKit. Read at
    /// launch and on every entitlement refresh; relaunch after changing it.
    /// Gated like the other test hooks in `RCamController.start()`: in a
    /// Release build the key does not exist, so it cannot be turned around
    /// into a bypass.
    private static var forceLocked: Bool {
        #if DEBUG
        return UserDefaults.standard.bool(forKey: "forceLocked")
        #else
        return false
        #endif
    }
}
