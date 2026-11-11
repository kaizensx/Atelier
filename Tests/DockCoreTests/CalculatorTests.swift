import Foundation
import Testing
@testable import DockCore

private func near(_ text: String, _ expected: Double) -> Bool {
    guard let value = Calculator.value(text) else { return false }
    return abs(value - expected) < 1e-9
}

@Test func calculatorArithmetic() {
    #expect(near("1+2*3", 7))
    #expect(near("(1+2)*3", 9))
    #expect(near("10/4", 2.5))
    #expect(near("2^10", 1024))
    #expect(near("2^3^2", 512))          // right-associative
    #expect(near("-2^2", -4))            // the power binds tighter than the sign
    #expect(near("2^-1", 0.5))
    #expect(near("--3", 3))
    #expect(near("7 % 3", 1))
    #expect(near("50%", 0.5))
    #expect(near("200 * 15%", 30))
    #expect(near("1.5 + 1,5", 3))        // a comma is a decimal point
    #expect(near("3x4", 12))
    #expect(near("6 × 7", 42))
    #expect(near("9 ÷ 3", 3))
    #expect(near(".5+.5", 1))
}

@Test func calculatorFunctionsAndConstants() {
    #expect(near("sqrt(16)", 4))
    #expect(near("abs(-3)", 3))
    #expect(near("round(2.6)", 3))
    #expect(near("log(1000)", 3))
    #expect(near("ln(e)", 1))
    #expect(near("sin(0)", 0))
    #expect(near("cos(pi)", -1))
    #expect(near("tan(0)", 0))
    #expect(near("2pi", 2 * .pi))
    #expect(near("2(3)", 6))
    #expect(near("(2)(3)", 6))
    #expect(near("SQRT(4)+PI-pi", 2))
}

@Test func calculatorRejectsWhatCrashedNSExpression() {
    for text in ["1+*2", "1.2.3+1", "1+", "*2", "()", "(1+2", "1+2)", "sqrt", "sqrt 4", "foo(2)", "2 $ 3",
                 "1/0", "5 % 0", "sqrt(-1)", "ln(0)", "", "   ", ".", "1..2", "pi(", ")(", "2^^3"] {
        #expect(Calculator.value(text) == nil, "\(text)")
        #expect(Calculator.evaluate(text) == nil, "\(text)")
    }
}

@Test func calculatorStaysOutOfSearches() {
    // Words and plain numbers are searches, not sums.
    for text in ["e", "pi", "42", "Safari", "x", "Final Cut", "1Password", "-5"] {
        #expect(Calculator.evaluate(text) == nil, "\(text)")
    }
    #expect(Calculator.evaluate("1+1") == 2.formatted(.number.precision(.fractionLength(0...6))))
    #expect(Calculator.evaluate("sqrt(2)") != nil)
}

@Test func calculatorBoundsNestingAndLength() {
    let deep = String(repeating: "(", count: 5000) + "1" + String(repeating: ")", count: 5000)
    #expect(Calculator.value(deep) == nil)
    let signs = String(repeating: "-", count: 5000) + "1"
    #expect(Calculator.value(signs) == nil)
    let shallow = String(repeating: "(", count: 20) + "1" + String(repeating: ")", count: 20)
    #expect(near(shallow, 1))
    #expect(Calculator.value(String(repeating: "1+", count: 150) + "1") == nil)
}
