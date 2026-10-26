import SwiftUI
import GestureCore

@main
struct GestureLabApp: App {
    @StateObject private var model = LabModel()

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                HomeView(model: model)
            }
        }
    }
}

struct HomeView: View {
    @ObservedObject var model: LabModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                Text("Gesture Lab")
                    .font(.system(size: 64, weight: .heavy))
                Text("Zkouška ovládání Siri Remote gesty pro přehrávač. Na testovací obrazovce ukončí test tlačítko Menu (zpět).")
                    .font(.system(size: 26))
                    .foregroundStyle(.secondary)

                Button {
                    model.startCapture(.test)
                } label: {
                    MenuRow(title: "Test gest", detail: "Živě: prst, stisky, rozpoznané gesto, akce na časové ose")
                }
                NavigationLink {
                    BindingsView(model: model)
                } label: {
                    MenuRow(title: "Přiřazení gest", detail: "Akce a jejich gesta, nahrání nového gesta")
                }
                NavigationLink {
                    DigitsView(model: model)
                } label: {
                    MenuRow(title: "Kreslení číslic", detail: "Vlastní vzory číslic 0–9")
                }
                NavigationLink {
                    TuningView(model: model)
                } label: {
                    MenuRow(title: "Ladění", detail: "Časy, délky, citlivost, způsob kreslení")
                }
            }
            .padding(80)
        }
    }
}

struct MenuRow: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 34, weight: .bold))
            Text(detail)
                .font(.system(size: 22))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
    }
}

/// A list row: name on the left, value on the right.
struct ValueRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 30, weight: .semibold))
            Spacer(minLength: 30)
            Text(value)
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Bindings

struct BindingsView: View {
    @ObservedObject var model: LabModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Přiřazení gest")
                    .font(.system(size: 52, weight: .heavy))
                Text("Vyber akci a udělej gesto. Play/Pause ho uloží. Gesto, které už patří jiné akci, se jí odebere.")
                    .font(.system(size: 24))
                    .foregroundStyle(.secondary)

                ForEach(LabAction.allCases, id: \.self) { action in
                    Button {
                        model.startCapture(.record(action))
                    } label: {
                        ValueRow(title: action.title, value: model.bindings.gesture(for: action)?.title ?? "—")
                    }
                    .contextMenu {
                        Button("Odebrat gesto", role: .destructive) { model.unbind(action) }
                    }
                }

                Button {
                    model.toggleDigitMode()
                } label: {
                    ValueRow(title: "Nakreslená číslice", value: model.bindings.digitMode.title)
                }
                Button(role: .destructive) {
                    model.resetBindings()
                } label: {
                    ValueRow(title: "Obnovit výchozí", value: "")
                }
                Text("Podržením tlačítka na akci gesto odebereš.")
                    .font(.system(size: 22))
                    .foregroundStyle(.secondary)
            }
            .padding(80)
        }
    }
}

// MARK: - Digits

struct DigitsView: View {
    @ObservedObject var model: LabModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Kreslení číslic")
                    .font(.system(size: 52, weight: .heavy))
                Text("Vyber číslici a nakresli ji 2–3×, každá kresba se uloží jako tvůj vzor. Kreslení začíná: \(model.tuning.drawingMode.title) (změníš v Ladění). V Testu gest se pak ukáže, co rozpoznání poznalo a s jakým skóre.")
                    .font(.system(size: 24))
                    .foregroundStyle(.secondary)

                ForEach(0..<10, id: \.self) { digit in
                    Button {
                        model.startCapture(.trainDigit(digit))
                    } label: {
                        ValueRow(title: "Číslice \(digit)", value: "vzorů: \(model.sampleCount(for: digit))")
                    }
                    .contextMenu {
                        Button("Smazat vzory \(digit)", role: .destructive) { model.deleteSamples(for: digit) }
                    }
                }

                Button {
                    model.useBuiltInDigits.toggle()
                } label: {
                    ValueRow(title: "Vestavěné tvary číslic", value: model.useBuiltInDigits ? "používat" : "jen moje vzory")
                }
                Button(role: .destructive) {
                    model.deleteSamples()
                } label: {
                    ValueRow(title: "Smazat všechny moje vzory", value: "")
                }
                Text("Podržením tlačítka u číslice smažeš jen její vzory.")
                    .font(.system(size: 22))
                    .foregroundStyle(.secondary)
            }
            .padding(80)
        }
    }
}

// MARK: - Tuning

struct TuningView: View {
    @ObservedObject var model: LabModel

    private struct Parameter: Identifiable {
        let id: String
        let title: String
        let hint: String
        let keyPath: WritableKeyPath<Tuning, Double>
        let step: Double
        let range: ClosedRange<Double>
        let format: (Double) -> String
    }

    private static let seconds: (Double) -> String = { String(format: "%.2f s", $0) }
    private static let units: (Double) -> String = { String(format: "%.2f", $0) }

    private let parameters: [Parameter] = [
        Parameter(id: "double", title: "Okno pro dvojklik", hint: "Jak dlouho se čeká na druhé kliknutí nebo dotyk",
                  keyPath: \.doubleWindow, step: 0.05, range: 0.15...0.6, format: TuningView.seconds),
        Parameter(id: "long", title: "Dlouhý stisk", hint: "Od kdy je stisk dlouhý",
                  keyPath: \.longPress, step: 0.1, range: 0.3...1.5, format: TuningView.seconds),
        Parameter(id: "swipeMin", title: "Nejkratší tah", hint: "Plocha má šířku 2,0",
                  keyPath: \.swipeMin, step: 0.1, range: 0.2...1.4, format: TuningView.units),
        Parameter(id: "swipeLong", title: "Dlouhý tah od", hint: "Tah aspoň takhle dlouhý je dlouhý",
                  keyPath: \.swipeLong, step: 0.1, range: 0.6...1.9, format: TuningView.units),
        Parameter(id: "swipeTime", title: "Nejpomalejší tah", hint: "Pomalejší pohyb už není tah",
                  keyPath: \.swipeMaxDuration, step: 0.1, range: 0.3...2.0, format: TuningView.seconds),
        Parameter(id: "tapTime", title: "Dotyk nejdéle", hint: "Delší dotyk není ťuknutí",
                  keyPath: \.tapMaxDuration, step: 0.05, range: 0.1...0.6, format: TuningView.seconds),
        Parameter(id: "tapMove", title: "Dotyk se smí posunout", hint: "Víc pohybu už není ťuknutí",
                  keyPath: \.tapMaxMovement, step: 0.05, range: 0.05...0.6, format: TuningView.units),
        Parameter(id: "side", title: "Hranice vlevo/vpravo", hint: "Dotyk dál od středu je vlevo nebo vpravo",
                  keyPath: \.sideThreshold, step: 0.05, range: 0.1...0.8, format: TuningView.units),
        Parameter(id: "circle", title: "Kroužek", hint: "Kolik stupňů je potřeba otočit",
                  keyPath: \.circleDegrees, step: 30, range: 180...720, format: { String(format: "%.0f°", $0) }),
        Parameter(id: "circleRadius", title: "Kroužek od okraje", hint: "Jak daleko od středu se musí kroužit",
                  keyPath: \.circleMinRadius, step: 0.05, range: 0.2...0.9, format: TuningView.units),
        Parameter(id: "arm", title: "Kreslení: čekání na první tah", hint: "Po dlouhém stisku",
                  keyPath: \.drawArmWindow, step: 0.5, range: 1...5, format: TuningView.seconds),
        Parameter(id: "gap", title: "Kreslení: konec po pauze", hint: "Pauza bez dotyku, která kreslení ukončí",
                  keyPath: \.strokeGap, step: 0.1, range: 0.3...2.0, format: TuningView.seconds),
        Parameter(id: "score", title: "Přísnost číslic", hint: "Nejnižší skóre (0–1), které se počítá",
                  keyPath: \.digitMinScore, step: 0.05, range: 0.2...0.95, format: TuningView.units),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Ladění")
                    .font(.system(size: 52, weight: .heavy))

                Button {
                    model.cycleDrawingMode()
                } label: {
                    ValueRow(title: "Kreslení číslic", value: model.tuning.drawingMode.title)
                }

                ForEach(parameters) { parameter in
                    HStack(spacing: 24) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(parameter.title)
                                .font(.system(size: 28, weight: .semibold))
                            Text(parameter.hint)
                                .font(.system(size: 20))
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 20)
                        Button {
                            model.adjust(parameter.keyPath, by: -parameter.step, in: parameter.range)
                        } label: {
                            Image(systemName: "minus")
                                .frame(width: 44)
                        }
                        Text(parameter.format(model.tuning[keyPath: parameter.keyPath]))
                            .font(.system(size: 28, weight: .bold).monospacedDigit())
                            .frame(width: 150)
                        Button {
                            model.adjust(parameter.keyPath, by: parameter.step, in: parameter.range)
                        } label: {
                            Image(systemName: "plus")
                                .frame(width: 44)
                        }
                    }
                    .focusSection()
                }

                Button(role: .destructive) {
                    model.resetTuning()
                } label: {
                    ValueRow(title: "Obnovit výchozí hodnoty", value: "")
                }
            }
            .padding(80)
        }
    }
}
