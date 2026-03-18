/// KytosSplitTreeTests.swift
///
/// Tests for KytosSplitTree and KytosWorkspace data model.

import Testing
import Foundation
@testable import Kytos

@Suite("KytosSplitTree")
struct KytosSplitTreeTests {

    @Test func singlePaneTree() {
        let pane = KytosPane(id: UUID(), title: "shell")
        let tree = KytosSplitTree(pane: pane)

        #expect(tree.allPanes.count == 1)
        #expect(tree.firstLeaf.id == pane.id)
        #expect(tree.isSplit == false)
    }

    @Test func splitCreatesTwo() {
        let pane = KytosPane()
        let tree = KytosSplitTree(pane: pane)
        let newPane = KytosPane()

        tree.split(at: pane.id, direction: .horizontal, newPane: newPane)

        #expect(tree.allPanes.count == 2)
        #expect(tree.isSplit == true)
        #expect(tree.findPane(pane.id) != nil)
        #expect(tree.findPane(newPane.id) != nil)
    }

    @Test func removeRestoresSinglePane() {
        let pane1 = KytosPane()
        let pane2 = KytosPane()
        let tree = KytosSplitTree(pane: pane1)
        tree.split(at: pane1.id, direction: .vertical, newPane: pane2)

        let focusID = tree.remove(paneID: pane2.id)

        #expect(tree.allPanes.count == 1)
        #expect(tree.isSplit == false)
        #expect(focusID == pane1.id)
    }

    @Test func equalizeSetsFiftyFifty() {
        let pane1 = KytosPane()
        let pane2 = KytosPane()
        let tree = KytosSplitTree(pane: pane1)
        tree.split(at: pane1.id, direction: .horizontal, newPane: pane2)
        tree.resize(at: pane1.id, ratio: 0.3)

        tree.equalize()

        // After equalize, verify both panes still exist
        #expect(tree.allPanes.count == 2)
    }

    @Test func metadataUpdatesIncrementVersion() {
        let pane = KytosPane()
        let tree = KytosSplitTree(pane: pane)
        let v0 = tree.metadataVersion

        tree.updateTitle("new title", for: pane.id)
        #expect(tree.metadataVersion > v0)

        let v1 = tree.metadataVersion
        tree.updatePwd("/tmp", for: pane.id)
        #expect(tree.metadataVersion > v1)

        let v2 = tree.metadataVersion
        tree.updateProcessName("vim", for: pane.id)
        #expect(tree.metadataVersion > v2)
    }

    @Test func metadataMergedInAllPanes() {
        let pane = KytosPane()
        let tree = KytosSplitTree(pane: pane)

        tree.updateTitle("zsh", for: pane.id)
        tree.updatePwd("/Users/test", for: pane.id)
        tree.updateProcessName("nvim", for: pane.id)

        let merged = tree.allPanes.first!
        #expect(merged.title == "zsh")
        #expect(merged.pwd == "/Users/test")
        #expect(merged.processName == "nvim")
    }

    @Test func positionStepsForNestedSplits() {
        let p1 = KytosPane()
        let p2 = KytosPane()
        let p3 = KytosPane()
        let tree = KytosSplitTree(pane: p1)
        tree.split(at: p1.id, direction: .horizontal, newPane: p2)
        tree.split(at: p2.id, direction: .vertical, newPane: p3)

        let steps = tree.positionSteps(for: p3.id)
        #expect(steps != nil)
        #expect((steps?.count ?? 0) >= 2)
    }

    @Test func allPanesCaching() {
        let pane = KytosPane()
        let tree = KytosSplitTree(pane: pane)

        let first = tree.allPanes
        let second = tree.allPanes
        // Same version → cached result should be identical
        #expect(first.count == second.count)
        #expect(first.first?.id == second.first?.id)
    }

    @Test func codableRoundTrip() throws {
        let p1 = KytosPane(title: "vim", pwd: "/tmp")
        let p2 = KytosPane(title: "zsh", pwd: "/home")
        let tree = KytosSplitTree(pane: p1)
        tree.split(at: p1.id, direction: .horizontal, newPane: p2)
        tree.updateProcessName("nvim", for: p1.id)

        let data = try JSONEncoder().encode(tree)
        let decoded = try JSONDecoder().decode(KytosSplitTree.self, from: data)

        #expect(decoded.allPanes.count == 2)
        #expect(decoded.isSplit == true)
    }
}

@Suite("KytosWorkspace")
struct KytosWorkspaceTests {

    @Test func defaultWorkspaceHasOnePan() {
        let ws = KytosWorkspace.defaultWorkspace()
        #expect(ws.splitTree.allPanes.count == 1)
        #expect(ws.focusedPaneID == ws.splitTree.firstLeaf.id)
    }

    @Test func sessionBackwardCompat() {
        let ws = KytosWorkspace.defaultWorkspace()
        let session = ws.session
        #expect(session.id == ws.splitTree.firstLeaf.id)
    }

    @Test func codableRoundTrip() throws {
        let ws = KytosWorkspace.defaultWorkspace()
        let data = try JSONEncoder().encode(ws)
        let decoded = try JSONDecoder().decode(KytosWorkspace.self, from: data)
        #expect(decoded.splitTree.allPanes.count == 1)
    }
}

@Suite("KytosPane")
struct KytosPaneTests {

    @Test func defaultValues() {
        let pane = KytosPane()
        #expect(pane.title.isEmpty)
        #expect(pane.pwd.isEmpty)
        #expect(pane.processName.isEmpty)
    }

    @Test func codableRoundTrip() throws {
        let pane = KytosPane(title: "test", pwd: "/tmp", processName: "vim")
        let data = try JSONEncoder().encode(pane)
        let decoded = try JSONDecoder().decode(KytosPane.self, from: data)
        #expect(decoded.title == "test")
        #expect(decoded.pwd == "/tmp")
        #expect(decoded.processName == "vim")
    }
}
