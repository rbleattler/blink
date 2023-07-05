//////////////////////////////////////////////////////////////////////////////////
//
// B L I N K
//
// Copyright (C) 2016-2023 Blink Mobile Shell Project
//
// This file is part of Blink.
//
// Blink is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// Blink is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with Blink. If not, see <http://www.gnu.org/licenses/>.
//
// In addition, Blink is also subject to certain additional terms under
// GNU GPL version 3 section 7.
//
// You should have received a copy of these additional terms immediately
// following the terms and conditions of the GNU General Public License
// which accompanied the Blink Source Code. If not, see
// <http://www.github.com/blinksh/blink>.
//
////////////////////////////////////////////////////////////////////////////////

import Combine
import Foundation
import BlinkSnippets
import UIKit
import SwiftUI
import HighlightSwift

class SearchModel: ObservableObject {
  weak var rootCtrl: UIViewController? = nil
  weak var inputView: UIView? = nil
  
  @Published var isOn = false
  
  var fuzzyResults = FuzzyAccumulator(query: "", style: .light(.xcode))
  var searchResults = SearchAccumulator(query: "", style: .light(.xcode))
  var fuzzyCancelable: AnyCancellable? = nil
  var searchCancelable: AnyCancellable? = nil

  //var fuzzyAttributedStrings: [Snippet: AttributedString] = [:]
  
  public var snippetContext: (any SnippetContext)? = nil
  
  var isFuzzyMode: Bool {
    self.searchResults.query.isEmpty
  }
  
  @Published var displayResults = [Snippet]() {
    didSet {
      if displayResults.isEmpty {
        self.selectedSnippetIdx = nil
      } else {
        self.selectedSnippetIdx = 0
      }
    }
  }
  
  @Published var selectedSnippetIdx: Int?
  
  @Published var currentSnippetName = ""
  @Published var editingSnippet: Snippet? = nil
  @Published var editingMode: TextViewEditingMode = .template
  @Published var newSnippetPresented = false
  @Published var indexProgress: SnippetsLocations.RefreshProgress = .none

  let snippetsLocations: SnippetsLocations
  // Stored Index snapshot to search.
  var index: [Snippet] = []
  var indexFetchCancellable: Cancellable? = nil
  var indexProgressCancellable: Cancellable? = nil
  
  var style: HighlightStyle = .light(.xcode) {
    didSet {
      searchResults.style = style
      fuzzyResults.style = style
      // new array to trigger repaint
      self.displayResults = Array(self.displayResults)
    }
  }

  func switchStyle(for scheme: ColorScheme) {
    if scheme == .dark {
      self.style = .dark(.xcode)
    } else {
      self.style = .light(.xcode)
    }
  }

  @Published private(set) var mode: SearchMode
  @Published private(set) var input: String {
    didSet {
      let splits = input.split(separator: " ", maxSplits: 1)
      guard
        self.mode != .general,
        let fuzzyQuery = splits.first
      else {
        self.fuzzyCancelable = nil
        self.searchCancelable = nil
        self.displayResults = []
        self.fuzzyResults.clear()
        self.searchResults.clear()
        return
      }
      var filterQuery = ""

      if splits.count == 2 {
        filterQuery = String(splits[1]).trimmingCharacters(in: .whitespacesAndNewlines)
      }

      let fQuery = String(fuzzyQuery)
//      fQuery.removeFirst()

      fuzzySearch(fQuery, filterQuery)
    }
  }

  

  init() throws {
    self.mode = .general
    self.input = ""
    
    self.snippetsLocations = try SnippetsLocations()
    
    self.indexFetchCancellable = self.snippetsLocations
      .indexPublisher
      // Refresh should happen on main thread, bc this is publishing changes.
      .receive(on: DispatchQueue.main)
      .sink(
      // Handle errors
      receiveCompletion: { _ in },
      receiveValue: { snippets in
        self.index = snippets
        self.input = { self.input }()
      })
    
    self.indexProgressCancellable = self.snippetsLocations
      .indexProgressPublisher
      .receive(on: DispatchQueue.main)
      .assign(to: \.indexProgress, on: self)
  }

  func updateWith(text: String) {
    self.mode = .insert
    self.input = text
    
//    if text.hasPrefix("<") {
//      self.mode = .insert
//    } else if text.hasPrefix("@") {
//      self.mode = .host
//    } else if text.hasPrefix("$") {
//      self.mode = .prompt
//    } else if text.hasPrefix(">") {
//      self.mode = .command
//    } else if text.hasPrefix("?") {
//      self.mode = .help
//    } else if text.hasPrefix("!") {
//      self.mode = .history
//    } else {
//      self.mode = .general
//    }

  }
  
  func insertRawSnippet() {
    guard let snippet = currentSelection
    else {
      return
    }
    do {
      let content = try snippet.content
      sendContentToReceiver(content: content)
    } catch {
      // TODO show error
    }
  }
  
  func copyRawSnippet() {
    guard let snippet = currentSelection
    else {
      return
    }
    do {
      let content = try snippet.content
      UIPasteboard.general.string = content
      self.close()
    } catch {
      // TODO show error
    }
  }

  func editSelectionOrCreate() {
    let snippet: Snippet
    if currentSelection == nil {
      if self.input.isEmpty {
        snippet = Snippet.scratch()
        self.editingMode = .code
      } else {
        openNewSnippet()
        return
      }
    } else {
      snippet = currentSelection!
      self.editingMode = .template
    }
    
    self.currentSnippetName = snippet.fuzzyIndex
    self.editingSnippet = snippet
    
    let textView = TextViewBuilder.createForSnippetEditing()
    let editorCtrl = EditorViewController(textView: textView, model: self)
    let navCtrl = UINavigationController(rootViewController: editorCtrl)
    navCtrl.modalPresentationStyle = .formSheet
    
    if let sheetCtrl = navCtrl.sheetPresentationController {
      sheetCtrl.prefersGrabberVisible = true
      sheetCtrl.prefersEdgeAttachedInCompactHeight = true
      sheetCtrl.widthFollowsPreferredContentSizeWhenEdgeAttached = true
      
      sheetCtrl.detents = [
        .custom(resolver: { context in
          120
        }),
        .medium(), .large()
      ]
      sheetCtrl.largestUndimmedDetentIdentifier = .large
    }
    rootCtrl?.present(navCtrl, animated: false)
    
  }
  
  func openNewSnippet() {
    self.newSnippetPresented = true
    let textView = TextViewBuilder.createForSnippetEditing()
    let editorCtrl = NewSnippetViewController(textView: textView, model: self)
    let navCtrl = UINavigationController(rootViewController: editorCtrl)
    navCtrl.modalPresentationStyle = .formSheet
    
    if let sheetCtrl = navCtrl.sheetPresentationController {
      sheetCtrl.prefersGrabberVisible = true
      sheetCtrl.prefersEdgeAttachedInCompactHeight = true
      sheetCtrl.widthFollowsPreferredContentSizeWhenEdgeAttached = true
      sheetCtrl.detents = [
        .medium(), .large()
      ]
      sheetCtrl.largestUndimmedDetentIdentifier = .large
    }
    rootCtrl?.present(navCtrl, animated: true)
    
  }

  @objc func sendContentToReceiver(content: String) {
    self.snippetContext?.providerSnippetReceiver()?.receive(content)
    self.isOn = false
    self.editingSnippet = nil
    self.input = ""
    self.snippetContext?.dismissSnippetsController()
  }
  
  func close() {
    self.isOn = false
    self.snippetContext?.dismissSnippetsController()
  }
  
  @objc func closeEditor() {
    self.editingSnippet = nil
    self.newSnippetPresented = false
    self.rootCtrl?.presentedViewController?.dismiss(animated: true)
  }
  
  func focusOnInput() {
    _ = self.inputView?.becomeFirstResponder()
  }

  func saveSnippet(newContent: String) {
    guard let snippet = self.editingSnippet else {
      return
    }
    
    try? self.snippetsLocations.saveSnippet(folder: snippet.folder, name: snippet.name, content: newContent)
  }

  func deleteSnippet() {
    guard let snippet = editingSnippet else {
      return
    }
    
    try? self.snippetsLocations.deleteSnippet(snippet: snippet)
    
    self.displayResults = []
    self.searchResults.clear()
    self.fuzzyResults.clear()
    self.input = ""
    self.editingSnippet = nil
  }
  
  func renameSnippet(newCategory: String, newName: String, newContent: String) {
    guard let snippet = self.editingSnippet else {
      return
    }
    if let newSnippet = try?
        self.snippetsLocations.renameSnippet(snippet: snippet, folder: newCategory, name: newName, content: newContent) {
      self.displayResults = []
      self.searchResults.clear()
      self.fuzzyResults.clear()
      self.input = ""
      self.editingSnippet = newSnippet
    }
  }
  
  func cleanString(str: String?) -> String {
    (str ?? "").lowercased()
      .replacingOccurrences(of: " ", with: "-")
      .replacingOccurrences(of: "/", with: "-")
      .replacingOccurrences(of: ".", with: "-")
      .replacingOccurrences(of: "~", with: "-")
      .replacingOccurrences(of: "\\", with: "-")
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  func refreshIndex() {
    self.snippetsLocations.refreshIndex(forceUpdate: true)
  }
}

public protocol SnippetReceiver {
  func receive(_ content: String)
}

public protocol SnippetContext {
  func presentSnippetsController()
  func dismissSnippetsController()
  func providerSnippetReceiver() -> (any SnippetReceiver)?
}

extension TermDevice: SnippetReceiver {
  public func receive(_ content: String) {
    self.view?.paste(content)
//    self.write(content)
  }
}

// MARK: Search

extension SearchModel {
  func fuzzySearch(_ query: String, _ searchQuery: String) {
    guard self.fuzzyResults.query != query
    else {
      return search(query: searchQuery)
    }

    self.searchCancelable = nil

    if query.isEmpty {
      self.fuzzyCancelable = nil
      self.displayResults = []
      self.fuzzyResults.clear()
      self.searchResults.clear()
      return
    }

    let query = query.lowercased()

    self.fuzzyCancelable = fuzzyResults
      .chooseSource(query: query, wideIndex: self.index)
      .fuzzySearch(searchString: query, maxResults: ResultsLimit)
      .subscribe(on: DispatchQueue.global())
      .reduce(FuzzyAccumulator(query: query, style: self.style), FuzzyAccumulator.accumulate(_:_:))
      .receive(on: DispatchQueue.main)
      .sink(
        receiveCompletion: { completion in
        },
        receiveValue: { fuzzyResults in
          self.fuzzyResults = fuzzyResults
          self.search(query: searchQuery)
        })
  }

  func search(query: String) {
    if self.fuzzyResults.isEmpty {
      self.displayResults = []
      return
    }

    if query.isEmpty {
      self.searchResults.clear()
      self.displayResults = self.fuzzyResults.snippets
      return
    }

    self.searchCancelable = searchResults
      .chooseSource(query: query, wideIndex: self.fuzzyResults.snippets)
      .publisher
      .subscribe(on: DispatchQueue.global())
      .map { s in (s, Search(content: s.searchableContent, searchString: query)) }
      .reduce(SearchAccumulator(query: query, style: self.style), SearchAccumulator.accumulate(_:_:))
      .receive(on: DispatchQueue.main)
      .sink(
        receiveCompletion: { _ in },
        receiveValue: { res in
          self.searchResults = res
          self.displayResults = res.snippets
        })
  }
}

// MARK: Snippet Selection
var generated: Bool = false

extension SearchModel {
  var currentSelection: Snippet? {
    if let idx = selectedSnippetIdx {
      return displayResults[idx]
    } else {
      return nil
    }
    
  }
  
  func onSnippetTap(_ snippet: Snippet) {
    if let index = self.displayResults.firstIndex(of: snippet) {
      self.selectedSnippetIdx = index
      self.editSelectionOrCreate()
    }
  }

  public func selectNextSnippet() {
    guard displayResults.count > 0  else {
      self.selectedSnippetIdx = nil
      return
    }
    guard let idx = self.selectedSnippetIdx else {
      self.selectedSnippetIdx = displayResults.count - 1
      return
    }

    self.selectedSnippetIdx = idx == 0 ? displayResults.count - 1 : idx - 1
  }

  public func selectPrevSnippet() {
    guard displayResults.count > 0  else {
      self.selectedSnippetIdx = nil
      return
    }
    guard let idx = self.selectedSnippetIdx else {
      self.selectedSnippetIdx = 0
      return
    }
    self.selectedSnippetIdx = (idx + 1 ) % displayResults.count
  }
}

// class CopySnippet: SnippetReceiver
// class TermInputSnippet: SnippetReceiver
// class CodeInputSnippet: SnippetReceiver
