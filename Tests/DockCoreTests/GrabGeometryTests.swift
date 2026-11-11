import CoreGraphics
import Foundation
import Testing
@testable import DockCore

private let window = CGRect(x: 100, y: 200, width: 800, height: 600)
private let floor = CGSize(width: 120, height: 60)

@Test func grabPicksTheQuadrantsCorner() {
    #expect(GrabGeometry.corner(for: CGPoint(x: 150, y: 250), in: window) == .init(right: false, bottom: false))
    #expect(GrabGeometry.corner(for: CGPoint(x: 850, y: 250), in: window) == .init(right: true, bottom: false))
    #expect(GrabGeometry.corner(for: CGPoint(x: 150, y: 750), in: window) == .init(right: false, bottom: true))
    #expect(GrabGeometry.corner(for: CGPoint(x: 850, y: 750), in: window) == .init(right: true, bottom: true))
    // The exact middle resizes from the bottom right.
    #expect(GrabGeometry.corner(for: CGPoint(x: 500, y: 500), in: window) == .init(right: true, bottom: true))
}

@Test func movingKeepsTheSize() {
    let moved = GrabGeometry.moved(window, by: CGVector(dx: 120, dy: 60))
    #expect(moved == CGRect(x: 220, y: 260, width: 800, height: 600))
}

@Test func bottomRightResizeKeepsTheOrigin() {
    let frame = GrabGeometry.resized(window, corner: .init(right: true, bottom: true), by: CGVector(dx: 80, dy: 40), minimum: floor)
    #expect(frame == CGRect(x: 100, y: 200, width: 880, height: 640))
}

@Test func topLeftResizeKeepsTheOppositeCorner() {
    let frame = GrabGeometry.resized(window, corner: .init(right: false, bottom: false), by: CGVector(dx: 50, dy: 30), minimum: floor)
    #expect(frame == CGRect(x: 150, y: 230, width: 750, height: 570))
    #expect(frame.maxX == window.maxX && frame.maxY == window.maxY)
}

@Test func resizeStopsAtTheMinimum() {
    // Pulling the left edge far past the right one leaves the smallest window, still pinned right.
    let frame = GrabGeometry.resized(window, corner: .init(right: false, bottom: true), by: CGVector(dx: 2000, dy: -2000), minimum: floor)
    #expect(frame.size == floor)
    #expect(frame.maxX == window.maxX)
    #expect(frame.minY == window.minY)
}

@Test func refusedSizesRaiseTheMinimum() {
    let learnt = GrabGeometry.learnMinimum(floor, asked: CGSize(width: 200, height: 100), got: CGSize(width: 340, height: 100))
    #expect(learnt == CGSize(width: 340, height: 60))
    // An app that took what it was given teaches nothing.
    #expect(GrabGeometry.learnMinimum(learnt, asked: CGSize(width: 500, height: 300), got: CGSize(width: 500, height: 300)) == learnt)
    // The origin follows the size the app really took.
    let origin = GrabGeometry.anchoredOrigin(window, corner: .init(right: false, bottom: false), size: CGSize(width: 340, height: 100))
    #expect(origin == CGPoint(x: 560, y: 700))
}

@Test func chordMustBeHeldExactly() {
    let chord = GrabGeometry.Chord.controlCommand
    #expect(chord.isHeld(in: [.maskControl, .maskCommand]))
    #expect(chord.isHeld(in: [.maskControl, .maskCommand, .maskAlphaShift]))
    #expect(!chord.isHeld(in: [.maskControl, .maskCommand, .maskShift]))
    #expect(!chord.isHeld(in: [.maskControl, .maskCommand, .maskAlternate]))
    #expect(!chord.isHeld(in: [.maskCommand]))
    #expect(GrabGeometry.Chord.allCases.map(\.symbols) == ["⌃⌘", "⌥⌘", "⌃⌥"])
}
