////////////////////////////////////////////////////////////////////////////
//
// Copyright 2021 Realm Inc.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//
////////////////////////////////////////////////////////////////////////////
import Foundation
import Realm

/// Enum representing an option for `String` queries.
public enum StringOptions {
    /// A case-insensitive search.
    case caseInsensitive
    /// Search ignores diacritic marks.
    case diacriticInsensitive
}

private enum QueryExpression {
    enum Prefix: String {
        case not = "NOT"
    }

    enum BasicComparision: String {
        case equal = "=="
        case notEqual = "!="
        case lessThan = "<"
        case greaterThan = ">"
        case greaterThenOrEqual = ">="
        case lessThanOrEqual = "<="
    }

    enum Comparision {
        case between(low: _QueryNumeric, high: _QueryNumeric, closedRange: Bool)
        case contains(_RealmSchemaDiscoverable?) // `IN` operator.
        case containsAny(NSArray) // `ANY ... IN` operator.
    }

    enum Compound: String {
        case and = "&&"
        case or = "||"
    }

    enum StringSearch {
        case contains(_QueryBinary, Set<StringOptions>?)
        case like(_QueryString, Set<StringOptions>?)
        case beginsWith(_QueryBinary, Set<StringOptions>?)
        case endsWith(_QueryBinary, Set<StringOptions>?)
        case equals(_QueryBinary, Set<StringOptions>?)
        case notEquals(_QueryBinary, Set<StringOptions>?)
    }

    enum CollectionAggregation: String {
        case min = ".@min"
        case max = ".@max"
        case avg = ".@avg"
        case sum = ".@sum"
        case count = ".@count"
        // Map only
        case allKeys = ".@allKeys"
        case allValues = ".@allValues"
    }

    enum Special {
        // Allows a prefixed `NOT` to be inserted where the
        // placeholder location is.
        case notPlaceholder
        case openParentheses
        case closeParentheses
        case anyInPrefix
    }

    case keyPath(name: String, isCollection: Bool = false)
    case prefix(Prefix)
    case comparison(Comparision)
    case basicComparison(BasicComparision)
    case compound(Compound)
    case rhs(_RealmSchemaDiscoverable?)
    case subquery(collection: String, predicate: String, args: [Any])
    case stringSearch(StringSearch)
    case collectionAggregation(CollectionAggregation)
    case keypathCollectionAggregation(CollectionAggregation)
    case special(Special)
}

private struct QueryContext {
    // Holds the individual tokens for the query expression.
    var expression: [QueryExpression] = []
    // Indicates if we need a closing parentheses after a map subscript expression.
    var mapSubscriptNeedsResolution = false
    // Helps give Subquery collection vars a unique name.
    var count = 0
    // Indicates if the query builder should use 'self' as the keypath.
    var isPrimitive = false

    init(expression: [QueryExpression] = [],
         count: Int,
         mapSubscriptNeedsResolution: Bool,
         isPrimitive: Bool) {
        self.expression = expression
        self.count = count
        self.mapSubscriptNeedsResolution = mapSubscriptNeedsResolution
        self.isPrimitive = isPrimitive
    }

    init(isPrimitive: Bool) {
        self.isPrimitive = isPrimitive
    }
}

/// Contains the components neccessary to construct an NSPredicate.
public struct QueryPredicate {
    /// The NSPredicate compatible string.
    public var predicate: String
    /// The arguments which should be passed to the NSPredicate.
    public var arguments: [Any]
    /// Used internally by the query constructor to keep track of Subqueries inside of Subqueries.
    fileprivate var subqueryCount: Int
}

/**
 `Query` is a class used to create type-safe query predicates.

 With `Query` you are given the ability to create Swift style query expression that will then
 be constructed into an `NSPredicate`. The `Query` class should not be instantiated directly
 and should be only used as a paramater within a closure that takes a query expression as an argument.
 Example:
 ```swift
 public func where(_ query: ((Query<Element>) -> Query<Element>)) -> Results<Element>
 ```

 You would then use the above function like so:
 ```swift
 let results = realm.objects(Person.self).query {
    $0.name == "Foo" || $0.name == "Bar" && $0.age >= 21
 }
 ```

 ## Supported predicate types

 ### Prefix
 - NOT `!`
 ```swift
 let results = realm.objects(Person.self).query {
    !$0.dogsName.contains("Fido") || !$0.name.contains("Foo")
 }
 ```

 ### Comparisions
 - Equals `==`
 - Not Equals `!=`
 - Greater Than `>`
 - Less Than `<`
 - Greater Than or Equal `>=`
 - Less Than or Equal `<=`
 - Between `.contains(_ range:)`

 ### Collections
 - IN `.contains(_ element:)`
 - Between `.contains(_ range:)`
 - ANY ... IN `.containsAnyIn(_ collection:)`


 ### Map
 - @allKeys `.keys`
 - @allValues `.values`

 ### Compound
 - AND `&&`
 - OR `||`

 ### Collection Aggregation
 - @avg `.avg`
 - @min `.min`
 - @max `.max`
 - @sum `.sum`
 - @count `.count`
 ```swift
 let results = realm.objects(Person.self).query {
    !$0.dogs.age.avg >= 0 || !$0.dogsAgesArray.avg >= 0
 }
 ```

 ### Other
 - NOT `!`
 - Subquery `($0.fooList.intCol >= 5).count > n`

 */
@dynamicMemberLookup
public struct Query<T: _RealmSchemaDiscoverable> {

    private var context: QueryContext

    /// Initializes a `Query` object.
    /// - Parameter isPrimitive: States is the query is on 'self' and will have no key path context.
    public init(isPrimitive: Bool = false) {
        self.context = QueryContext(isPrimitive: isPrimitive)
    }

    fileprivate init(context: QueryContext) {
        self.context = context
        if self.context.isPrimitive {
            // Do not insert 'self' where it does not make a logical
            // predicate expression.
            if case .special = self.context.expression.first {
                return
            }
            self.context.expression.insert(.keyPath(name: "self", isCollection: false), at: 0)
        }
    }

    private func append<V>(expression: [QueryExpression], subqueryCount: Int? = nil) -> Query<V> {
        var copy = expression
        var needsResolution = context.mapSubscriptNeedsResolution
        var lastTokenIsKeyPath = false
        if case .keyPath = expression.last {
            lastTokenIsKeyPath = true
        }
        if !lastTokenIsKeyPath, context.mapSubscriptNeedsResolution {
            copy.append(.special(.closeParentheses))
            needsResolution = false
        }

        return Query<V>(context: QueryContext(expression: context.expression + copy,
                                              count: (subqueryCount != nil) ? subqueryCount! : context.count,
                                              mapSubscriptNeedsResolution: needsResolution,
                                              isPrimitive: context.isPrimitive))
    }

    // MARK: Prefix

    /// :nodoc:
    public static prefix func ! (_ rhs: Query) -> Query {
        var contextCopy = rhs.context
        let hasPlaceholder = !contextCopy.expression.enumerated().reversed().filter {
            if case let .special(s) = $0.element, s == .notPlaceholder {
                contextCopy.expression.remove(at: $0.offset)
                contextCopy.expression.insert(.prefix(.not), at: $0.offset)
                return true
            } else {
                return false
            }
        }.isEmpty
        if !hasPlaceholder {
            contextCopy.expression.insert(.prefix(.not), at: 0)
        }
        return Query(context: contextCopy)
    }

    // MARK: Comparable

    /// :nodoc:
    public static func == <V>(_ lhs: Query<V>, _ rhs: V) -> Query where V: _RealmSchemaDiscoverable {
        return lhs.append(expression: [.basicComparison(.equal), .rhs(rhs)])
    }
    /// :nodoc:
    public static func != <V>(_ lhs: Query<V>, _ rhs: V) -> Query where V: _RealmSchemaDiscoverable {
        return lhs.append(expression: [.basicComparison(.notEqual), .rhs(rhs)])
    }

    // MARK: Numerics

    /// :nodoc:
    public static func > <V>(_ lhs: Query<V>, _ rhs: V) -> Query where V: _QueryNumeric {
        return lhs.append(expression: [.basicComparison(.greaterThan), .rhs(rhs)])
    }
    /// :nodoc:
    public static func >= <V>(_ lhs: Query<V>, _ rhs: V) -> Query where V: _QueryNumeric {
        return lhs.append(expression: [.basicComparison(.greaterThenOrEqual), .rhs(rhs)])
    }
    /// :nodoc:
    public static func < <V>(_ lhs: Query<V>, _ rhs: V) -> Query where V: _QueryNumeric {
        return lhs.append(expression: [.basicComparison(.lessThan), .rhs(rhs)])
    }
    /// :nodoc:
    public static func <= <V>(_ lhs: Query<V>, _ rhs: V) -> Query where V: _QueryNumeric {
        return lhs.append(expression: [.basicComparison(.lessThanOrEqual), .rhs(rhs)])
    }

    // MARK: Compound

    /// :nodoc:
    public static func && (_ lhs: Query, _ rhs: Query) -> Query {
        // Wrap the left expression and right expression in parentheses
        var copy = lhs
        copy.context.expression.insert(.special(.openParentheses), at: 0)
        return copy.append(expression: [.compound(.and)] + rhs.context.expression + [.special(.closeParentheses)],
                           subqueryCount: rhs.context.count)
    }
    /// :nodoc:
    public static func || (_ lhs: Query, _ rhs: Query) -> Query {
        // Wrap the left expression and right expression in parentheses
        var copy = lhs
        copy.context.expression.insert(.special(.openParentheses), at: 0)
        return copy.append(expression: [.compound(.or)] + rhs.context.expression + [.special(.closeParentheses)],
                           subqueryCount: rhs.context.count)
    }

    // MARK: Subscript

    /// :nodoc:
    public subscript<V>(dynamicMember member: KeyPath<T, V>) -> Query<V> where T: ObjectBase {
        let name = _name(for: member)
        return append(expression: [.keyPath(name: name)])
    }
    /// :nodoc:
    public subscript<V: RealmCollectionBase>(dynamicMember member: KeyPath<T, V>) -> Query<V> where T: ObjectBase {
        let name = _name(for: member)
        return append(expression: [.keyPath(name: name, isCollection: true)])
    }

    // MARK: Query Construction

    /// Creates an NSPredicate compatibe string.
    /// - Parameter isSubquery: States if expression need to be arraged in a special way to cater to subqueries.
    /// - Returns: A tuple containing the predicate string and an array of arguments.
    public func _constructPredicate(_ isSubquery: Bool = false) -> QueryPredicate {
        var predicateString: [String] = []
        var arguments: [Any] = []
        var subqueryCount = context.count

        func optionsStr(_ options: Set<StringOptions>?) -> String {
            guard let o = options, !o.isEmpty else {
                return ""
            }
            var str = "["
            if o.contains(.caseInsensitive) {
                str += "c"
            }
            if o.contains(.diacriticInsensitive) {
                str += "d"
            }
            str += "]"
            return str
        }

        func comparison(_ expression: QueryExpression.Comparision, _ idx: Int) {
            switch expression {
            case let .between(low, high, closedRange):
                if closedRange {
                    predicateString.append(" BETWEEN {%@, %@}")
                    arguments.append(contentsOf: [low, high])
                } else if idx > 0, case let .keyPath(name, _) = context.expression[idx-1] {
                    predicateString.append(" >= %@")
                    arguments.append(low)
                    predicateString.append(" && \(name) <\(closedRange ? "=" : "") %@")
                    arguments.append(high)
                } else {
                    throwRealmException("Could not construct .contains(_:) predicate")
                }
            case let .contains(val):
                predicateString.insert("%@ IN ", at: predicateString.count-1)
                arguments.append(val.objCValue)
            case let .containsAny(col):
                predicateString.append(" IN %@")
                arguments.append(col)
            }
        }

        func keyPath(_ name: String,
                     _ idx: Int,
                     _ isCollection: Bool,
                     _ isSubquery: Bool) -> Bool {
            if isCollection && isSubquery {
                predicateString.append("$placeholder")
                return true
            }
            var needsDot = false
            if idx > 0, case .keyPath = context.expression[idx-1] {
                needsDot = true
            }
            if needsDot {
                predicateString.append(".")
            }
            predicateString.append("\(name)")
            return false
        }

        func stringSearch(_ expression: QueryExpression.StringSearch) {
            switch expression {
            case let .contains(str, options):
                predicateString.append(" CONTAINS\(optionsStr(options)) %@")
                arguments.append(str)
            case let .like(str, options):
                predicateString.append(" LIKE\(optionsStr(options)) %@")
                arguments.append(str)
            case let .beginsWith(str, options):
                predicateString.append(" BEGINSWITH\(optionsStr(options)) %@")
                arguments.append(str)
            case let .endsWith(str, options):
                predicateString.append(" ENDSWITH\(optionsStr(options)) %@")
                arguments.append(str)
            case let .equals(str, options):
                predicateString.append(" ==\(optionsStr(options)) %@")
                arguments.append(str)
            case let .notEquals(str, options):
                predicateString.append(" !=\(optionsStr(options)) %@")
                arguments.append(str)
            }
        }

        func subquery(_ collectionName: String, _ predicate: String, _ args: [Any]) {
            // To handle the edge case of a Subquery in a Subquery we need to give
            // each collection var a unique identifier.
            let collectionKey = "$obj\(context.count)"
            let replacedStr = predicate.replacingOccurrences(of: "$placeholder", with: collectionKey)
            let subqueryStr = "SUBQUERY(\(collectionName), \(collectionKey), \(replacedStr)).@count"
            predicateString.append(subqueryStr)
            arguments.append(contentsOf: args)
            subqueryCount += 1
        }

        func keyPathCollectionAggregation(_ expression: QueryExpression.CollectionAggregation,
                                          _ idx: Int) {
            // Aggregates only work on numeric types if they are used as keypath in a collection.
            // We take 2 steps back to ensure that from where the aggregation operator is placed
            // there is a key path to the property.
            if idx-2 >= 0,
               case let .keyPath(_, isCollection) = context.expression[idx-2],
               isCollection {
                predicateString.insert(expression.rawValue, at: predicateString.count-2)
            } else {
                throwRealmException("Could not aggregate `\(expression.rawValue)`, property is not within a collection.")
            }
        }

        func special(_ expression: QueryExpression.Special) {
            switch expression {
            case .openParentheses:
                predicateString.append("(")
            case .closeParentheses:
                predicateString.append(")")
            case .notPlaceholder:
                break
            case .anyInPrefix:
                predicateString.append("ANY ")
            }
        }

        for (idx, token) in context.expression.enumerated() {
            switch token {
            case let .prefix(op):
                predicateString.append("\(op.rawValue) ")
            case let .basicComparison(op):
                predicateString.append(" \(op.rawValue)")
            case let .comparison(comp):
                comparison(comp, idx)
            case let .compound(comp):
                predicateString.append(" \(comp.rawValue) ")
            case let .keyPath(name, isCollection):
                let shouldContinue = keyPath(name, idx, isCollection, isSubquery)
                if shouldContinue {
                    continue
                }
            case let .stringSearch(s):
                stringSearch(s)
            case let .rhs(v):
                predicateString.append(" %@")
                arguments.append(v.objCValue)
            case let .subquery(col, str, args):
                subquery(col, str, args)
            case let .collectionAggregation(agg):
                predicateString.append(agg.rawValue)
            case let .keypathCollectionAggregation(agg):
                keyPathCollectionAggregation(agg, idx)
            case let .special(s):
                special(s)
            }
        }

        return QueryPredicate(predicate: predicateString.joined(),
                              arguments: arguments,
                              subqueryCount: subqueryCount)
    }

    internal var predicate: NSPredicate {
        let query = _constructPredicate()
        return NSPredicate(format: query.predicate, argumentArray: query.arguments)
    }

    private func aggregateContains<U: _QueryNumeric, V>(_ lowerBound: U,
                                                        _ upperBound: U,
                                                        isClosedRange: Bool=false) -> Query<V> {
        guard let keyPath = context.expression.first else {
            throwRealmException("Could not construct aggregate query, key path is missing.")
        }
        return append(expression: [.collectionAggregation(.min),
                               .basicComparison(.greaterThenOrEqual),
                               .rhs(lowerBound),
                               .compound(.and),
                               keyPath,
                               .collectionAggregation(.max),
                               .basicComparison(isClosedRange ? .lessThanOrEqual : .lessThan),
                               .rhs(upperBound)])
    }

    private func doContainsAny<U: Sequence, V>(in collection: U) -> Query<V> {
        var keyPathDepth = 0
        for token in context.expression.reversed() {
            if case .keyPath = token {
                keyPathDepth += 1
            } else {
                break
            }
        }
        precondition(keyPathDepth != 0)
        var copy = self
        copy.context.expression.insert(.special(.anyInPrefix), at: context.expression.count - keyPathDepth)
        return copy.append(expression: [.comparison(.containsAny(NSArray(array: collection.map(dynamicBridgeCast))))])
    }
}

// MARK: OptionalProtocol

extension Query where T: OptionalProtocol {
    /// :nodoc:
    public subscript<V>(dynamicMember member: KeyPath<T.Wrapped, V>) -> Query<V> where T.Wrapped: ObjectBase {
        let name = _name(for: member)
        return append(expression: [.keyPath(name: name)])
    }
}

// MARK: RealmCollection

extension Query where T: RealmCollection {
    /// :nodoc:
    public subscript<V>(dynamicMember member: KeyPath<T.Element, V>) -> Query<V> where T.Element: ObjectBase {
        let name = _name(for: member)
        return append(expression: [.keyPath(name: name)])
    }

    /// Query the count of the objects in the collection.
    public var count: Query<Int> {
        return append(expression: [.collectionAggregation(.count)])
    }
}

extension Query where T: RealmCollection {
    /// Checks if an element exists in this collection.
    public func contains<V>(_ value: T.Element) -> Query<V> {
        return append(expression: [.comparison(.contains(value))])
    }

    /// Checks if any elements contained in the given array are present in the collection.
    public func containsAny<U: Sequence, V>(in collection: U) -> Query<V> where U.Element == T.Element {
        return doContainsAny(in: collection)
    }
}

extension Query where T: RealmCollection, T.Element: _QueryNumeric {
    /// Checks for all elements in this collection that are within a given range.
    public func contains<V>(_ range: Range<T.Element>) -> Query<V> {
        return aggregateContains(range.lowerBound, range.upperBound)
    }

    /// Checks for all elements in this collection that are within a given range.
    public func contains<V>(_ range: ClosedRange<T.Element>) -> Query<V> {
        return aggregateContains(range.lowerBound, range.upperBound, isClosedRange: true)
    }
}

extension Query where T: RealmCollection, T.Element: OptionalProtocol, T.Element.Wrapped: _QueryNumeric {
    /// Checks for all elements in this collection that are within a given range.
    public func contains<V>(_ range: Range<T.Element.Wrapped>) -> Query<V> {
        return aggregateContains(range.lowerBound, range.upperBound)
    }

    /// Checks for all elements in this collection that are within a given range.
    public func contains<V>(_ range: ClosedRange<T.Element.Wrapped>) -> Query<V> {
        return aggregateContains(range.lowerBound, range.upperBound, isClosedRange: true)
    }
}

extension Query where T: RealmCollection, T.Element: _QueryNumeric {
    /// :nodoc:
    public static func == <V>(_ lhs: Query<T>, _ rhs: T.Element) -> Query<V> {
        return lhs.append(expression: [.basicComparison(.equal), .rhs(rhs)])
    }

    /// :nodoc:
    public static func != <V>(_ lhs: Query<T>, _ rhs: T.Element) -> Query<V> {
        return lhs.append(expression: [.basicComparison(.notEqual), .rhs(rhs)])
    }

    /// :nodoc:
    public static func > <V>(_ lhs: Query<T>, _ rhs: T.Element) -> Query<V> {
        return lhs.append(expression: [.basicComparison(.greaterThan), .rhs(rhs)])
    }

    /// :nodoc:
    public static func >= <V>(_ lhs: Query<T>, _ rhs: T.Element) -> Query<V> {
        return lhs.append(expression: [.basicComparison(.greaterThenOrEqual), .rhs(rhs)])
    }

    /// :nodoc:
    public static func < <V>(_ lhs: Query<T>, _ rhs: T.Element) -> Query<V> {
        return lhs.append(expression: [.basicComparison(.lessThan), .rhs(rhs)])
    }

    /// :nodoc:
    public static func <= <V>(_ lhs: Query<T>, _ rhs: T.Element) -> Query<V> {
        return lhs.append(expression: [.basicComparison(.lessThanOrEqual), .rhs(rhs)])
    }
}

extension Query where T: RealmCollection,
                      T.Element: _QueryNumeric {
    /// Returns the minimum value in the collection.
    public var min: Query {
        return append(expression: [.collectionAggregation(.min)])
    }

    /// Returns the maximum value in the collection.
    public var max: Query {
        return append(expression: [.collectionAggregation(.max)])
    }

    /// Returns the average in the collection.
    public var avg: Query {
        return append(expression: [.collectionAggregation(.avg)])
    }

    /// Returns the sum of all the values in the collection.
    public var sum: Query {
        return append(expression: [.collectionAggregation(.sum)])
    }
}

// MARK: RealmKeyedCollection

extension Query where T: RealmKeyedCollection {
    private func memberSubscript<U>(_ member: T.Key) -> Query<U> where T.Key: _RealmSchemaDiscoverable {
        guard let keyPath = context.expression.first else {
            throwRealmException("Could not contruct predicate for Map")
        }
        var copy = context
        copy.mapSubscriptNeedsResolution = true
        copy.expression.insert(.special(.openParentheses), at: 0)
        copy.expression.append(contentsOf: [.collectionAggregation(.allKeys),
                                            .basicComparison(.equal),
                                            .rhs(member),
                                            .compound(.and),
                                            .special(.notPlaceholder),
                                            keyPath])
        return Query<U>(context: copy)
    }

    /// Checks if any elements contained in the given array are present in the map's values.
    public func containsAny<U: Sequence, V>(in collection: U) -> Query<V> where U.Element == T.Value {
        return doContainsAny(in: collection)
    }
}

extension Query where T: RealmKeyedCollection, T.Key: _RealmSchemaDiscoverable {
    /// Checks if an element exists in this collection.
    public func contains<V>(_ value: T.Value) -> Query<V> {
        return append(expression: [.comparison(.contains(value))])
    }
    /// Allows a query over all values in the Map.
    public var values: Query<T.Value> {
        return append(expression: [.collectionAggregation(.allValues)])
    }
    /// :nodoc:
    public subscript(member: T.Key) -> Query<T.Value> {
        return memberSubscript(member)
    }
}

extension Query where T: RealmKeyedCollection, T.Key: _RealmSchemaDiscoverable, T.Value: OptionalProtocol, T.Value.Wrapped: _RealmSchemaDiscoverable {
    /// Allows a query over all values in the Map.
    public var values: Query<T.Value.Wrapped> {
        return append(expression: [.collectionAggregation(.allValues)])
    }
    /// :nodoc:
    public subscript(member: T.Key) -> Query<T.Value.Wrapped> {
        return memberSubscript(member)
    }
    /// :nodoc:
    public subscript(member: T.Key) -> Query<T.Value> where T.Value.Wrapped: ObjectBase {
        return memberSubscript(member)
    }
}

extension Query where T: RealmKeyedCollection, T.Key == String {
    /// Allows a query over all keys in the `Map`.
    public var keys: Query<String> {
        return append(expression: [.collectionAggregation(.allKeys)])
    }
}

extension Query where T: RealmKeyedCollection, T.Value: _QueryNumeric {
    /// Checks for all elements in this collection that are within a given range.
    public func contains<V>(_ range: Range<T.Value>) -> Query<V> {
        return aggregateContains(range.lowerBound, range.upperBound)
    }

    /// Checks for all elements in this collection that are within a given range.
    public func contains<V>(_ range: ClosedRange<T.Value>) -> Query<V> {
        return aggregateContains(range.lowerBound, range.upperBound, isClosedRange: true)
    }
}

extension Query where T: RealmKeyedCollection, T.Value: OptionalProtocol, T.Value.Wrapped: _QueryNumeric {
    /// Checks for all elements in this collection that are within a given range.
    public func contains<V>(_ range: Range<T.Value.Wrapped>) -> Query<V> {
        return aggregateContains(range.lowerBound, range.upperBound)
    }

    /// Checks for all elements in this collection that are within a given range.
    public func contains<V>(_ range: ClosedRange<T.Value.Wrapped>) -> Query<V> {
        return aggregateContains(range.lowerBound, range.upperBound, isClosedRange: true)
    }
}

extension Query where T: RealmKeyedCollection,
                      T.Key: _RealmSchemaDiscoverable,
                      T.Value: _QueryNumeric {
    /// Returns the minimum value in the keyed collection.
    public var min: Query<T.Value> {
        return append(expression: [.collectionAggregation(.min)])
    }

    /// Returns the maximum value in the keyed collection.
    public var max: Query<T.Value> {
        return append(expression: [.collectionAggregation(.max)])
    }

    /// Returns the average in the keyed collection.
    public var avg: Query<T.Value> {
        return append(expression: [.collectionAggregation(.avg)])
    }

    /// Returns the sum of all the values in the keyed collection.
    public var sum: Query<T.Value> {
        return append(expression: [.collectionAggregation(.sum)])
    }

    /// Returns the count of all the values in the keyed collection.
    public var count: Query<T.Value> {
        return append(expression: [.collectionAggregation(.count)])
    }
}

// MARK: PersistableEnum

extension Query where T: PersistableEnum, T.RawValue: _RealmSchemaDiscoverable {
    /// :nodoc:
    public static func == <V>(_ lhs: Query<T>, _ rhs: T) -> Query<V> {
        return lhs.append(expression: [.basicComparison(.equal), .rhs(rhs.rawValue)])
    }
    /// :nodoc:
    public static func != <V>(_ lhs: Query<T>, _ rhs: T) -> Query<V> {
        return lhs.append(expression: [.basicComparison(.notEqual), .rhs(rhs.rawValue)])
    }
    /// :nodoc:
    public static func > <V>(_ lhs: Query<T>, _ rhs: T) -> Query<V> where T.RawValue: _QueryNumeric {
        return lhs.append(expression: [.basicComparison(.greaterThan), .rhs(rhs.rawValue)])
    }
    /// :nodoc:
    public static func >= <V>(_ lhs: Query<T>, _ rhs: T) -> Query<V> where T.RawValue: _QueryNumeric {
        return lhs.append(expression: [.basicComparison(.greaterThenOrEqual), .rhs(rhs.rawValue)])
    }
    /// :nodoc:
    public static func < <V>(_ lhs: Query<T>, _ rhs: T) -> Query<V> where T.RawValue: _QueryNumeric {
        return lhs.append(expression: [.basicComparison(.lessThan), .rhs(rhs.rawValue)])
    }
    /// :nodoc:
    public static func <= <V>(_ lhs: Query<T>, _ rhs: T) -> Query<V> where T.RawValue: _QueryNumeric {
        return lhs.append(expression: [.basicComparison(.lessThanOrEqual), .rhs(rhs.rawValue)])
    }
}

extension Query where T: PersistableEnum,
                      T.RawValue: _QueryNumeric {
    /// Returns the minimum value in the collection based on the keypath.
    public var min: Query {
        return append(expression: [.keypathCollectionAggregation(.min)])
    }

    /// Returns the maximum value in the collection based on the keypath.
    public var max: Query {
        return append(expression: [.keypathCollectionAggregation(.max)])
    }

    /// Returns the average in the collection based on the keypath.
    public var avg: Query {
        return append(expression: [.keypathCollectionAggregation(.avg)])
    }

    /// Returns the sum of all the values in the collection based on the keypath.
    public var sum: Query {
        return append(expression: [.keypathCollectionAggregation(.sum)])
    }

    /// Returns the count of all the values in the collection based on the keypath.
    public var count: Query {
        return append(expression: [.keypathCollectionAggregation(.count)])
    }
}

// MARK: Optional

extension Query where T: OptionalProtocol,
                      T.Wrapped: PersistableEnum,
                      T.Wrapped.RawValue: _RealmSchemaDiscoverable {
    /// :nodoc:
    public static func == <V>(_ lhs: Query<T>, _ rhs: T) -> Query<V> {
        if case Optional<Any>.none = rhs as Any {
            return lhs.append(expression: [.basicComparison(.equal), .rhs(nil)])
        } else {
            return lhs.append(expression: [.basicComparison(.equal), .rhs(rhs._rlmInferWrappedType().rawValue)])
        }
    }
    /// :nodoc:
    public static func != <V>(_ lhs: Query<T>, _ rhs: T) -> Query<V> {
        if case Optional<Any>.none = rhs as Any {
            return lhs.append(expression: [.basicComparison(.notEqual), .rhs(nil)])
        } else {
            return lhs.append(expression: [.basicComparison(.notEqual), .rhs(rhs._rlmInferWrappedType().rawValue)])
        }
    }
}

extension Query where T: OptionalProtocol, T.Wrapped: PersistableEnum, T.Wrapped.RawValue: _QueryNumeric {
    /// :nodoc:
    public static func > <V>(_ lhs: Query<T>, _ rhs: T) -> Query<V> {
        if case Optional<Any>.none = rhs as Any {
            return lhs.append(expression: [.basicComparison(.greaterThan), .rhs(nil)])
        } else {
            return lhs.append(expression: [.basicComparison(.greaterThan), .rhs(rhs._rlmInferWrappedType().rawValue)])
        }
    }
    /// :nodoc:
    public static func >= <V>(_ lhs: Query<T>, _ rhs: T) -> Query<V> {
        if case Optional<Any>.none = rhs as Any {
            return lhs.append(expression: [.basicComparison(.greaterThenOrEqual), .rhs(nil)])
        } else {
            return lhs.append(expression: [.basicComparison(.greaterThenOrEqual), .rhs(rhs._rlmInferWrappedType().rawValue)])
        }
    }
    /// :nodoc:
    public static func < <V>(_ lhs: Query<T>, _ rhs: T) -> Query<V> {
        if case Optional<Any>.none = rhs as Any {
            return lhs.append(expression: [.basicComparison(.lessThan), .rhs(nil)])
        } else {
            return lhs.append(expression: [.basicComparison(.lessThan), .rhs(rhs._rlmInferWrappedType().rawValue)])
        }
    }
    /// :nodoc:
    public static func <= <V>(_ lhs: Query<T>, _ rhs: T) -> Query<V> {
        if case Optional<Any>.none = rhs as Any {
            return lhs.append(expression: [.basicComparison(.lessThanOrEqual), .rhs(nil)])
        } else {
            return lhs.append(expression: [.basicComparison(.lessThanOrEqual), .rhs(rhs._rlmInferWrappedType().rawValue)])
        }
    }
}

extension Query where T: OptionalProtocol,
                      T.Wrapped: PersistableEnum,
                      T.Wrapped.RawValue: _QueryNumeric {
    /// Returns the minimum value in the collection based on the keypath.
    public var min: Query {
        return append(expression: [.keypathCollectionAggregation(.min)])
    }

    /// Returns the maximum value in the collection based on the keypath.
    public var max: Query {
        return append(expression: [.keypathCollectionAggregation(.max)])
    }

    /// Returns the average in the collection based on the keypath.
    public var avg: Query {
        return append(expression: [.keypathCollectionAggregation(.avg)])
    }

    /// Returns the sum of all the value in the collection based on the keypath.
    public var sum: Query {
        return append(expression: [.keypathCollectionAggregation(.sum)])
    }
}

// MARK: _QueryNumeric

extension Query where T: _QueryNumeric {
    /// Checks for all elements in this collection that are within a given range.
    public func contains<V>(_ range: Range<T>) -> Query<V> {
        return append(expression: [.comparison(.between(low: range.lowerBound,
                                                    high: range.upperBound, closedRange: false))])
    }

    /// Checks for all elements in this collection that are within a given range.
    public func contains<V>(_ range: ClosedRange<T>) -> Query<V> {
        return append(expression: [.comparison(.between(low: range.lowerBound,
                                                    high: range.upperBound, closedRange: true))])
    }
}

// MARK: _QueryString

extension Query where T: _QueryString {
    /**
    Checks for all elements in this collection that equal the given value.
    `?` and `*` are allowed as wildcard characters, where `?` matches 1 character and `*` matches 0 or more characters.
     - parameter value: value used.
     - parameter caseInsensitive: `true` if it is a case-insensitive search.
     */
    public func like<V>(_ value: T, caseInsensitive: Bool = false) -> Query<V> {
        return append(expression: [.stringSearch(.like(value, caseInsensitive ? [.caseInsensitive] : []))])
    }
}

// MARK: _QueryBinary

extension Query where T: _QueryBinary {
    /**
    Checks for all elements in this collection that contains the given value.
    - parameter value: value used.
    - parameter options: A Set of options used to evaluate the Search query.
    */
    public func contains<V>(_ value: T, options: Set<StringOptions>? = nil) -> Query<V> {
        return append(expression: [.stringSearch(.contains(value, options))])
    }

    /**
    Checks for all elements in this collection that starts with the given value.
     - parameter value: value used.
     - parameter options: A Set of options used to evaluate the Search query.
     */
    public func starts<V>(with value: T, options: Set<StringOptions>? = nil) -> Query<V> {
        return append(expression: [.stringSearch(.beginsWith(value, options))])
    }

    /**
    Checks for all elements in this collection that ends with the given value.
    - parameter value: value used.
    - parameter options: A Set of options used to evaluate the Search query.
    */
    public func ends<V>(with value: T, options: Set<StringOptions>? = nil) -> Query<V> {
        return append(expression: [.stringSearch(.endsWith(value, options))])
    }

    /**
    Checks for all elements in this collection that equals the given value.
    - parameter value: value used.
    - parameter options: A Set of options used to evaluate the Search query.
    */
    public func equals<V>(_ value: T, options: Set<StringOptions>? = nil) -> Query<V> {
        return append(expression: [.stringSearch(.equals(value, options))])
    }

    /**
    Checks for all elements in this collection that are not equal to the given value.
    - parameter value: value used.
    - parameter options: A Set of options used to evaluate the Search query.
    */
    public func notEquals<V>(_ value: T, options: Set<StringOptions>? = nil) -> Query<V> {
        return append(expression: [.stringSearch(.notEquals(value, options))])
    }
}

extension Query where T: OptionalProtocol, T.Wrapped: _QueryNumeric {
    /// Checks for all elements in this collection that are within a given range.
    public func contains<V>(_ range: Range<T.Wrapped>) -> Query<V> {
        return append(expression: [.comparison(.between(low: range.lowerBound,
                                                    high: range.upperBound, closedRange: false))])
    }

    /// Checks for all elements in this collection that are within a given range.
    public func contains<V>(_ range: ClosedRange<T.Wrapped>) -> Query<V> {
        return append(expression: [.comparison(.between(low: range.lowerBound,
                                                    high: range.upperBound, closedRange: true))])
    }
}

// MARK: Subquery

extension Query where T == Bool {
    /// Completes a subquery expression.
    /// ```
    /// ($0.myCollection.age >= 21).count > 0
    /// ```
    public var count: Query<Int> {
        let collections = Set(context.expression.filter {
            if case let .keyPath(_, isCollection) = $0 {
                return isCollection ? true : false
            }
            return false
        }.map { kp -> String in
            if case let .keyPath(name, _) = kp {
                return name
            }
            throwRealmException("Could not create subquery expression.")
        })

        if collections.count > 1 {
            throwRealmException("Subquery predicates will only work on one collection at a time.")
        }
        let query = _constructPredicate(true)
        let c = QueryContext(expression: [.subquery(collection: collections.first!,
                                                    predicate: query.predicate,
                                                    args: query.arguments)],
                             count: query.subqueryCount,
                             mapSubscriptNeedsResolution: false,
                             isPrimitive: context.isPrimitive)
        return Query<Int>(context: c)
    }
}

// MARK: Keypath Collection Aggregates

/**
 You can use only use aggregates in numeric types as a keypath on a collection.
 ```swift
 let results = realm.objects(Person.self).query {
   !$0.dogs.age.avg >= 0
 }
 ```
 Where `dogs` is an array of objects.
 */
extension Query where T: _QueryNumeric {
    /// Returns the minimum value of the objects in the collection based on the keypath.
    public var min: Query {
        return append(expression: [.keypathCollectionAggregation(.min)])
    }

    /// Returns the maximum value of the objects in the collection based on the keypath.
    public var max: Query {
        return append(expression: [.keypathCollectionAggregation(.max)])
    }

    /// Returns the average of the objects in the collection based on the keypath.
    public var avg: Query {
        return append(expression: [.keypathCollectionAggregation(.avg)])
    }

    /// Returns the sum of the objects in the collection based on the keypath.
    public var sum: Query {
        return append(expression: [.keypathCollectionAggregation(.sum)])
    }
}

/// Tag protocol for all numeric types.
public protocol _QueryNumeric: _RealmSchemaDiscoverable { }
extension Int: _QueryNumeric { }
extension Int8: _QueryNumeric { }
extension Int16: _QueryNumeric { }
extension Int32: _QueryNumeric { }
extension Int64: _QueryNumeric { }
extension Float: _QueryNumeric { }
extension Double: _QueryNumeric { }
extension Decimal128: _QueryNumeric { }
extension Date: _QueryNumeric { }
extension AnyRealmValue: _QueryNumeric { }
extension Optional: _QueryNumeric where Wrapped: _QueryNumeric { }

/// Tag protocol for all types that are compatible with `String`.
public protocol _QueryString: _QueryBinary { }
extension String: _QueryString { }
extension Optional: _QueryString where Wrapped: _QueryString { }

/// Tag protocol for all types that are compatible with `Binary`.
public protocol _QueryBinary { }
extension Data: _QueryBinary { }
extension Optional: _QueryBinary where Wrapped: _QueryBinary { }
