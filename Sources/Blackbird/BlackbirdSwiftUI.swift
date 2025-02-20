//
//           /\
//          |  |                       Blackbird
//          |  |
//         .|  |.       https://github.com/marcoarment/Blackbird
//         $    $
//        /$    $\          Copyright 2022–2023 Marco Arment
//       / $|  |$ \          Released under the MIT License
//      .__$|  |$__.
//           \/
//
//  BlackbirdSwiftUI.swift
//  Created by Marco Arment on 12/5/22.
//
//  Permission is hereby granted, free of charge, to any person obtaining a copy
//  of this software and associated documentation files (the "Software"), to deal
//  in the Software without restriction, including without limitation the rights
//  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//  copies of the Software, and to permit persons to whom the Software is
//  furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in all
//  copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
//  SOFTWARE.
//

import SwiftUI
import Combine

struct EnvironmentBlackbirdDatabaseKey: EnvironmentKey {
    static var defaultValue: Blackbird.Database? = nil
}

extension EnvironmentValues {
    /// The ``Blackbird/Database`` to use with `@BlackbirdLive…` property wrappers.
    public var blackbirdDatabase: Blackbird.Database? {
        get { self[EnvironmentBlackbirdDatabaseKey.self] }
        set { self[EnvironmentBlackbirdDatabaseKey.self] = newValue }
    }
}

extension Blackbird {
    /// The results wrapper for @BlackbirdLiveQuery and @BlackbirdLiveModels.
    public struct LiveResults<T: Sendable>: Sendable, Equatable where T: Equatable {
        public static func == (lhs: Blackbird.LiveResults<T>, rhs: Blackbird.LiveResults<T>) -> Bool { lhs.didLoad == rhs.didLoad && lhs.results == rhs.results }
        
        /// The latest results fetched.
        public var results: [T] = []
        
        /// Whether this result set has **ever** completed loading.
        ///
        /// When used by ``BlackbirdLiveModels`` or ``BlackbirdLiveQuery``, this will only be set to `false` during their initial load.
        /// It will **not** be set to `false` during subsequent updates triggered by changes to the underlying database.
        public var didLoad = false
        
        public init(results: [T] = [], didLoad: Bool = false) {
            self.results = results
            self.didLoad = didLoad
        }
    }
}

// MARK: - Fetch property wrappers

/// An array of database rows produced by a generator function, kept up-to-date as data changes in the specified table.
///
/// Set `@Environment(\.blackbirdDatabase)` to the desired database instance to read.
///
/// The generator is passed the current database as its sole argument (`$0`).
///
/// ## Example
///
/// ```swift
/// @BlackbirdLiveQuery(tableName: "Post", {
///     try await $0.query("SELECT COUNT(*) AS c FROM Post")
/// }) var count
/// ```
///
/// `count` is a ``Blackbird/LiveResults`` object:
/// * `count.results.first["c"]` will be the resulting ``Blackbird/Value``
/// * `count.didLoad` will be `false` during the initial load (useful for displaying a loading state in the UI)
///
@propertyWrapper public struct BlackbirdLiveQuery: DynamicProperty {
    @State private var results = Blackbird.LiveResults<Blackbird.Row>()
    @Environment(\.blackbirdDatabase) var environmentDatabase

    public var wrappedValue: Blackbird.LiveResults<Blackbird.Row> {
        get { results }
        set { }
    }

    private let queryUpdater: Blackbird.QueryUpdater
    private let generator: Blackbird.CachedResultGenerator<[Blackbird.Row]>
    private let tableName: String

    public init(tableName: String, _ generator: @escaping Blackbird.CachedResultGenerator<[Blackbird.Row]>) {
        self.tableName = tableName
        self.generator = generator
        self.queryUpdater = Blackbird.QueryUpdater()
    }

    public func update() {
        queryUpdater.bind(from: environmentDatabase, tableName: tableName, to: $results, generator: generator)
    }
}

/// An array of ``BlackbirdModel`` instances produced by a generator function, kept up-to-date as their table's data changes in the database.
///
/// Set `@Environment(\.blackbirdDatabase)` to the desired database instance to read.
///
/// The generator is passed the current database as its sole argument (`$0`).
///
/// ## Example
///
/// ```swift
/// @BlackbirdLiveModels({
///     try await Post.read(from: $0, where: "id > 3 ORDER BY date")
/// }) var posts
/// ```
///
/// `posts` is a ``Blackbird/LiveResults`` object:
/// * `posts.results` will be an array of Post models matching the query
/// * `posts.didLoad` will be `false` during the initial load (useful for displaying a loading state in the UI)
///
@propertyWrapper public struct BlackbirdLiveModels<T: BlackbirdModel>: DynamicProperty {
    @State private var result = Blackbird.LiveResults<T>()
    @Environment(\.blackbirdDatabase) var environmentDatabase
    
    public var wrappedValue: Blackbird.LiveResults<T> {
        get { result }
        set { }
    }
    
    private let queryUpdater = Blackbird.ModelArrayUpdater<T>()
    private let generator: Blackbird.CachedResultGenerator<[T]>

    public init(_ generator: @escaping Blackbird.CachedResultGenerator<[T]>) {
        self.generator = generator
    }

    public func update() {
        queryUpdater.bind(from: environmentDatabase, to: $result, generator: generator)
    }
}

/// A single ``BlackbirdModel`` instance, kept up-to-date as its data changes in the database.
///
/// Set `@Environment(\.blackbirdDatabase)` to the desired database instance to read.
///
/// The ``BlackbirdModel/liveModel-swift.property`` property is helpful when initializing child views with a specific instance.
///
/// Example:
///
/// ```swift
/// // In a parent view:
/// ForEach(posts) { post in
///     NavigationLink(destination: PostView(post: post.liveModel)) {
///         Text(post.title)
///     }
/// }
///
/// // Child view:
/// struct PostView: View {
///     @BlackbirdLiveModel var post: Post?
///     // will be kept up-to-date
/// }
/// ```
@propertyWrapper public struct BlackbirdLiveModel<T: BlackbirdModel>: DynamicProperty {
    @State private var instance: T?
    private var instanceObserver: BlackbirdModelInstanceChangeObserver<T>
    @Environment(\.blackbirdDatabase) var environmentDatabase
    
    public var changePublisher: AnyPublisher<T?, Never> { instanceObserver.changePublisher }

    public var updatesEnabled: Bool {
        get { instanceObserver.updatesEnabled }
        nonmutating set { instanceObserver.updatesEnabled = newValue }
    }
    
    public var wrappedValue: T? {
        get { instance }
        nonmutating set { instance = newValue }
    }
    
    public init(_ instance: T, updatesEnabled: Bool = true) {
        _instance = State(initialValue: instance)
        instanceObserver = BlackbirdModelInstanceChangeObserver<T>(primaryKeyValues: try! instance.primaryKeyValues().map { try! Blackbird.Value.fromAny($0) })
        instanceObserver.updatesEnabled = updatesEnabled
    }

    public init(type: T.Type, primaryKeyValues: [Any], updatesEnabled: Bool = true) {
        _instance = State(initialValue: nil)
        instanceObserver = BlackbirdModelInstanceChangeObserver<T>(primaryKeyValues: primaryKeyValues.map { try! Blackbird.Value.fromAny($0) } )
        instanceObserver.updatesEnabled = updatesEnabled
    }

    public mutating func update() {
        instanceObserver.observe(database: environmentDatabase, currentInstance: $instance)
    }
}

public final class BlackbirdModelInstanceChangeObserver<T: BlackbirdModel> {
    private let primaryKeyValues: [Blackbird.Value]
    private let changeObserver = Blackbird.Locked<AnyCancellable?>(nil)
    private var currentDatabase: Blackbird.Database? = nil
    private var hasEverUpdated = false
    
    private var _changePublisher = PassthroughSubject<T?, Never>()
    public var changePublisher: AnyPublisher<T?, Never> { _changePublisher.eraseToAnyPublisher() }

    public var updatesEnabled = true {
        didSet {
            Task.detached { [weak self] in await self?.update() }
        }
    }
    
    private let cachedInstance = Blackbird.Locked<T?>(nil)
    @Binding public var currentInstance: T?

    public init(primaryKeyValues: [Blackbird.Value]) {
        self.primaryKeyValues = primaryKeyValues
        _currentInstance = Binding<T?>(get: { nil }, set: { _ in })
    }
    
    public func observe(database: Blackbird.Database?, currentInstance: Binding<T?>) {
        _currentInstance = currentInstance
        guard let database, database != currentDatabase else { return }
        currentDatabase = database
        cachedInstance.value = nil

        let primaryKeyValues = primaryKeyValues
        changeObserver.value = T.changePublisher(in: database, multicolumnPrimaryKey: primaryKeyValues)
        .sink { _ in
            Task.detached { [weak self] in
                self?.cachedInstance.value = nil
                await self?.update()
            }
        }
        
        Task.detached { [weak self] in await self?.update() }
    }
    
    public func update() async {
        guard let currentDatabase, updatesEnabled else { return }
                
        if let cachedInstance = cachedInstance.value {
            currentInstance = cachedInstance
            await MainActor.run {
                _changePublisher.send(cachedInstance)
            }
            return
        }
        
        let instance = try? await T.read(from: currentDatabase, multicolumnPrimaryKey: primaryKeyValues)
        cachedInstance.value = instance
        await MainActor.run {
            currentInstance = instance
            _changePublisher.send(instance)
        }
    }
}

extension BlackbirdModel {
    /// A convenience accessor to a ``BlackbirdLiveModel`` instance with the given single-column primary-key value. Useful for SwiftUI.
    ///
    /// For models with multi-column primary keys, see ``liveModel(multicolumnPrimaryKey:updatesEnabled:)``.
    public static func liveModel(primaryKey: Any, updatesEnabled: Bool = true) -> BlackbirdLiveModel<Self> {
        BlackbirdLiveModel<Self>(type: Self.self, primaryKeyValues: [primaryKey], updatesEnabled: updatesEnabled)
    }

    /// A convenience accessor to a ``BlackbirdLiveModel`` instance with the given multi-column primary-key value. Useful for SwiftUI.
    ///
    /// For models with single-column primary keys, see ``liveModel(primaryKey:updatesEnabled:)``.
    public static func liveModel(multicolumnPrimaryKey: [Any], updatesEnabled: Bool = true) -> BlackbirdLiveModel<Self> {
        BlackbirdLiveModel<Self>(type: Self.self, primaryKeyValues: multicolumnPrimaryKey, updatesEnabled: updatesEnabled)
    }


    /// A convenience accessor to this instance's ``BlackbirdLiveModel``. Useful for SwiftUI.
    public var liveModel: BlackbirdLiveModel<Self> { get { BlackbirdLiveModel(self) } }

    /// Shorthand for this model's ``Blackbird/LiveResults`` type.
    public typealias LiveResults = Blackbird.LiveResults<Self>
    
    /// Shorthand for this model's ``BlackbirdLiveModel`` type.
    public typealias LiveModel = BlackbirdLiveModel<Self>
}

// MARK: - Multi-row query updaters

extension Blackbird {
    /// Used in Blackbird's SwiftUI primitives.
    public final class QueryUpdater: @unchecked Sendable { // unchecked due to internal locking
        @Binding public var results: Blackbird.LiveResults<Blackbird.Row>

        private let resultPublisher = CachedResultPublisher<[Blackbird.Row]>()
        private var changePublishers: [AnyCancellable] = []
        private let lock = Blackbird.Lock()

        public init() {
            _results = Binding<Blackbird.LiveResults<Blackbird.Row>>(get: { Blackbird.LiveResults<Blackbird.Row>() }, set: { _ in })
        }
        
        public func bind(from database: Blackbird.Database?, tableName: String, to results: Binding<Blackbird.LiveResults<Blackbird.Row>>, generator: CachedResultGenerator<[Blackbird.Row]>?) {
            lock.lock()
            defer { lock.unlock() }
        
            changePublishers.removeAll()
            resultPublisher.subscribe(to: tableName, in: database, generator: generator)
            _results = results
            
            changePublishers.append(resultPublisher.valuePublisher.sink { [weak self] value in
                guard let self else { return }
                let results: Blackbird.LiveResults<Blackbird.Row>
                if let value {
                    results = Blackbird.LiveResults<Blackbird.Row>(results: value, didLoad: true)
                } else {
                    results = Blackbird.LiveResults<Blackbird.Row>(results: [], didLoad: false)
                }
                
                DispatchQueue.main.async { // kicking this to the next runloop to prevent state updates from happening while building the view
                    self.results = results
                }
            })
        }
    }

    /// Used in Blackbird's SwiftUI primitives.
    public final class ModelArrayUpdater<T: BlackbirdModel>: @unchecked Sendable { // unchecked due to internal locking
        @Binding public var results: Blackbird.LiveResults<T>

        private let resultPublisher: CachedResultPublisher<[T]>
        private var changePublishers: [AnyCancellable] = []
        private let lock = Blackbird.Lock()

        public init(initialValue: [T]? = nil) {
            _results = Binding<Blackbird.LiveResults<T>>(get: { Blackbird.LiveResults<T>(results: initialValue ?? [], didLoad: initialValue != nil) }, set: { _ in })
            resultPublisher = CachedResultPublisher<[T]>(initialValue: initialValue)
        }
        
        public func bind(from database: Blackbird.Database?, to results: Binding<Blackbird.LiveResults<T>>, generator: CachedResultGenerator<[T]>?) {
            lock.lock()
            defer { lock.unlock() }
            
            changePublishers.removeAll()
            resultPublisher.subscribe(to: T.table.name, in: database, generator: generator)
            _results = results
            
            changePublishers.append(resultPublisher.valuePublisher.sink { [weak self] value in
                guard let self else { return }
                DispatchQueue.main.async {
                    if let value {
                        self.results = Blackbird.LiveResults<T>(results: value, didLoad: true)
                    } else {
                        self.results = Blackbird.LiveResults<T>(results: [], didLoad: false)
                    }
                }
            })
        }
    }
}

// MARK: - Single-instance updater

extension Blackbird {
    /// Used in Blackbird's SwiftUI primitives.
    public final class ModelInstanceUpdater<T: BlackbirdModel>: @unchecked Sendable { // unchecked due to internal locking
        @Binding public var instance: T?
        @Binding public var didLoad: Bool
        private let bindingLock = Blackbird.Lock()
        
        private struct State {
            var changeObserver: AnyCancellable? = nil
            var database: Blackbird.Database? = nil
            var primaryKeyValues: [Blackbird.Value]? = nil
        }
        
        private let state = Blackbird.Locked(State())

        public init() {
            _instance = Binding<T?>(get: { nil }, set: { _ in })
            _didLoad = Binding<Bool>(get: { false }, set: { _ in })
        }

        /// Update a binding with the current instance matching a single-column primary-key value named `"id"`, and keep it updated over time.
        /// - Parameters:
        ///   - database: The database to read from and monitor for changes.
        ///   - instance: A binding to store the matching instance in. Will be set to `nil` if the database does not contain a matching instance.
        ///   - didLoad: An optional binding that will be set to `true` after the **first** load of the specified instance has completed.
        ///   - id: The ID value to match, assuming the table has a single-column primary key named `"id"`.
        ///
        /// See also: ``bind(from:to:didLoad:primaryKey:)`` and ``bind(from:to:didLoad:multicolumnPrimaryKey:)`` .
        public func bind(from database: Blackbird.Database?, to instance: Binding<T?>, didLoad: Binding<Bool>? = nil, id: Sendable) {
            bind(from: database, to: instance, didLoad: didLoad, multicolumnPrimaryKey: [id])
        }

        /// Update a binding with the current instance matching a single-column primary-key value, and keep it updated over time.
        /// - Parameters:
        ///   - database: The database to read from and monitor for changes.
        ///   - instance: A binding to store the matching instance in. Will be set to `nil` if the database does not contain a matching instance.
        ///   - didLoad: An optional binding that will be set to `true` after the **first** load of the specified instance has completed.
        ///   - primaryKey: The single-column primary-key value to match.
        ///
        /// See also: ``bind(from:to:didLoad:multicolumnPrimaryKey:)`` and ``bind(from:to:didLoad:id:)``.
        public func bind(from database: Blackbird.Database?, to instance: Binding<T?>, didLoad: Binding<Bool>? = nil, primaryKey: Sendable) {
            bind(from: database, to: instance, didLoad: didLoad, multicolumnPrimaryKey: [primaryKey])
        }

        /// Update a binding with the current instance matching a multi-column primary-key value, and keep it updated over time.
        /// - Parameters:
        ///   - database: The database to read from and monitor for changes.
        ///   - instance: A binding to store the matching instance in. Will be set to `nil` if the database does not contain a matching instance.
        ///   - didLoad: An optional binding that will be set to `true` after the **first** load of the specified instance has completed.
        ///   - multicolumnPrimaryKey: The multi-column primary-key values to match.
        ///
        /// See also: ``bind(from:to:didLoad:primaryKey:)`` and ``bind(from:to:didLoad:id:)``.
        public func bind(from database: Blackbird.Database?, to instance: Binding<T?>, didLoad: Binding<Bool>? = nil, multicolumnPrimaryKey: [Sendable]) {
            bindingLock.withLock {
                self._instance = instance
                if let didLoad { self._didLoad = didLoad }
            }
        
            state.withLock { state in
                state.database = database
                state.primaryKeyValues = multicolumnPrimaryKey.map { try! Blackbird.Value.fromAny($0) }
                if let database, let primaryKeyValues = state.primaryKeyValues {
                    state.changeObserver = T.changePublisher(in: database, multicolumnPrimaryKey: primaryKeyValues)
                    .sink { _ in
                        Task.detached { [weak self] in
                            guard let self else { return }
                            let instance = try? await T.read(from: database, multicolumnPrimaryKey: primaryKeyValues)
                            await MainActor.run {
                                self.instance = instance
                                self.didLoad = true
                            }
                        }
                    }
                } else {
                    state.changeObserver = nil
                }
            }
            
            update()
        }
        
        internal func update() {
            let (database, primaryKeyValues) = state.withLock { state in (state.database, state.primaryKeyValues) }
            guard let database, let primaryKeyValues else { return }
        
            Task.detached { [weak self] in
                guard let self else { return }
                let instance = try? await T.read(from: database, multicolumnPrimaryKey: primaryKeyValues)
                await MainActor.run {
                    self.instance = instance
                    self.didLoad = true
                }
            }
        }
    }
}
