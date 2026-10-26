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
                    TuningView(model: model)
                } label: {
                    MenuRow(title: "Ladění", detail: "Časy, délky, citlivost")
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
    private static let points: (Double) -> String = { String(format: "%.0f b", $0) }

    private let parameters: [Parameter] = [
        Parameter(id: "double", title: "Okno pro dvojklik", hint: "Od puštění prvního kliknutí (dotyku) do druhého",
                  keyPath: \.doubleWindow, step: 0.05, range: 0.15...0.8, format: TuningView.seconds),
        Parameter(id: "long", title: "Dlouhý stisk", hint: "Od kdy je stisk dlouhý",
                  keyPath: \.longPress, step: 0.1, range: 0.3...1.5, format: TuningView.seconds),
        Parameter(id: "swipeMin", title: "Nejkratší tah", hint: "Posun UIKit v bodech (je vidět v logu)",
                  keyPath: \.swipeMinPoints, step: 25, range: 50...1500, format: TuningView.points),
        Parameter(id: "swipeLong", title: "Dlouhý tah od", hint: "Posun UIKit v bodech",
                  keyPath: \.swipeLongPoints, step: 50, range: 200...3000, format: TuningView.points),
        Parameter(id: "swipeTime", title: "Nejpomalejší tah", hint: "Pomalejší pohyb už není tah",
                  keyPath: \.swipeMaxDuration, step: 0.1, range: 0.3...2.0, format: TuningView.seconds),
        Parameter(id: "backLength", title: "Tam a zpět: nejkratší cesta", hint: "Cesta tam na ploše (celá plocha je 2), zpět aspoň polovina",
                  keyPath: \.swipeBackMinLength, step: 0.05, range: 0.2...1.6, format: TuningView.units),
        Parameter(id: "backTime", title: "Tam a zpět nejdéle", hint: "Pomalejší pohyb už není tah tam a zpět",
                  keyPath: \.swipeBackMaxDuration, step: 0.25, range: 0.5...4.0, format: TuningView.seconds),
        Parameter(id: "tapTime", title: "Dotyk nejdéle", hint: "Delší dotyk není ťuknutí",
                  keyPath: \.tapMaxDuration, step: 0.05, range: 0.1...0.6, format: TuningView.seconds),
        Parameter(id: "tapMove", title: "Dotyk se smí posunout", hint: "Posun UIKit v bodech, víc už není ťuknutí",
                  keyPath: \.tapMaxMovePoints, step: 10, range: 10...400, format: TuningView.points),
        Parameter(id: "clickGuard", title: "Odstup od kliknutí", hint: "Dotyk takhle blízko kliknutí patří ke kliknutí",
                  keyPath: \.clickGuard, step: 0.05, range: 0...0.5, format: TuningView.seconds),
        Parameter(id: "liftTrim", title: "Ořez při zvednutí prstu", hint: "Polohy těsně před zvednutím se zahodí",
                  keyPath: \.liftTrim, step: 0.01, range: 0...0.2, format: TuningView.seconds),
        Parameter(id: "side", title: "Velikost středu", hint: "Dotyk dál od středu je vlevo, vpravo, nahoře, dole (nebo v rohu)",
                  keyPath: \.sideThreshold, step: 0.05, range: 0.1...0.8, format: TuningView.units),
        Parameter(id: "cornerWidth", title: "Šířka rohů", hint: "Úhel kolem úhlopříčky, který patří rohu",
                  keyPath: \.cornerWidth, step: 5, range: 10...80, format: { String(format: "%.0f°", $0) }),
        Parameter(id: "holdMin", title: "Přidržení od", hint: "Jak dlouho musí prst ležet bez cvaknutí",
                  keyPath: \.holdMinDuration, step: 0.1, range: 0.3...2.0, format: TuningView.seconds),
        Parameter(id: "holdSpread", title: "Přidržení: povolený pohyb", hint: "Jak daleko se smí prst při přidržení posunout",
                  keyPath: \.holdMaxSpread, step: 0.05, range: 0.05...0.8, format: TuningView.units),
        Parameter(id: "circle", title: "Kroužek", hint: "Kolik stupňů je potřeba otočit",
                  keyPath: \.circleDegrees, step: 30, range: 180...720, format: { String(format: "%.0f°", $0) }),
        Parameter(id: "circleRadius", title: "Kroužek od okraje", hint: "Jak daleko od středu se musí kroužit",
                  keyPath: \.circleMinRadius, step: 0.05, range: 0.2...0.9, format: TuningView.units),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Ladění")
                    .font(.system(size: 52, weight: .heavy))

                Button {
                    model.tuning.cornerTouches.toggle()
                } label: {
                    ValueRow(title: "Dotyky v rozích", value: model.tuning.cornerTouches ? "zapnuté" : "vypnuté")
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
