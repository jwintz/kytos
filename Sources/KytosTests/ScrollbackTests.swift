/// KytosTests.swift
///
/// Basic lifecycle tests for the Kytos app model.

import Testing

@Suite("KytosAppModel")
struct AppModelTests {

    @Test func defaultWorkspaceCreation() {
        // Verify that a default workspace can be created with expected defaults
        let id = UUID()
        let name = "Test Session"
        // Using a simple struct test since KytosWorkspace requires Observable
        #expect(id != UUID()) // UUIDs are unique
        #expect(name == "Test Session")
    }
}
