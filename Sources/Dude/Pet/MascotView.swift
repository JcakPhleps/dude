import SwiftUI

/// The living stick-figure. Cycles sprite frames and bobs based on Dude's mood.
struct MascotView: View {
    @ObservedObject var brain: Brain

    @State private var tick = 0
    @State private var blinking = false

    private let timer = Timer.publish(every: 0.32, on: .main, in: .common).autoconnect()

    var body: some View {
        PixelSprite(frame: currentFrame)
            .offset(y: bobOffset)
            .animation(.easeInOut(duration: 0.35), value: bobOffset)
            .onReceive(timer) { _ in
                tick &+= 1
                // Occasional blink on the idle beat.
                if brain.mood == .idle, tick % 7 == 0 {
                    blinking = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) {
                        blinking = false
                    }
                }
            }
            .accessibilityLabel("Dude, your desktop buddy")
    }

    private var currentFrame: [String] {
        if blinking { return Sprites.blink }
        switch brain.mood {
        case .dancing:
            return Sprites.dance[tick % Sprites.dance.count]
        case .walking:
            return Sprites.walk[tick % Sprites.walk.count]
        case .atLaptop:
            return Sprites.laptop[tick % Sprites.laptop.count]
        case .celebrating:
            return Sprites.celebrate[tick % Sprites.celebrate.count]
        case .working:
            return Sprites.working[tick % Sprites.working.count]
        case .listening:
            return Sprites.listen[tick % Sprites.listen.count]
        case .voice:
            return Sprites.voice[tick % Sprites.voice.count]
        case .talking:
            return tick.isMultiple(of: 2) ? Sprites.talk : Sprites.idleA
        case .thinking:
            return Sprites.think[tick % Sprites.think.count]
        case .stumped:
            return Sprites.idleB
        case .idle:
            return tick.isMultiple(of: 2) ? Sprites.idleA : Sprites.idleB
        }
    }

    private var bobOffset: CGFloat {
        switch brain.mood {
        case .celebrating:
            return tick.isMultiple(of: 2) ? -7 : 3   // big excited hop
        case .dancing:
            return tick.isMultiple(of: 2) ? -4 : 4
        case .walking:
            return tick.isMultiple(of: 2) ? -3 : 3
        case .voice:
            return tick.isMultiple(of: 2) ? -3 : 3
        case .thinking, .talking, .listening:
            return tick.isMultiple(of: 2) ? -2 : 2
        default:
            return tick.isMultiple(of: 2) ? -1 : 1
        }
    }
}
