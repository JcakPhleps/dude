import Foundation

/// Pixel-art frames for the mascot, authored on a 16x16 grid.
///
/// Legend:
///   `.` transparent   `K` ink (outline)   `W` body fill   `E` eye
///
/// Every row must be exactly `DudeTheme.spriteGrid` characters wide; this is
/// asserted when a frame is first rendered.
enum Sprites {
    // Relaxed stance: shoulders squared, arms hanging easy at his sides.
    static let idleA = [
        "................",
        ".....KKKKKK.....",
        "....KWWWWWWK....",
        "....KWEWWEWK....",
        "....KWWWWWWK....",
        ".....KKKKKK.....",
        ".....KKKKKK.....",
        ".....K.KK.K.....",
        ".....K.KK.K.....",
        ".......KK.......",
        ".......KK.......",
        "......K..K......",
        ".....K....K.....",
        ".....K....K.....",
        "................",
        "................",
    ]

    // Second beat of the idle breath — elbows bend in a touch.
    static let idleB = [
        "................",
        ".....KKKKKK.....",
        "....KWWWWWWK....",
        "....KWEWWEWK....",
        "....KWWWWWWK....",
        ".....KKKKKK.....",
        ".....KKKKKK.....",
        ".....K.KK.K.....",
        "......KKKK......",
        ".......KK.......",
        ".......KK.......",
        "......K..K......",
        ".....K....K.....",
        ".....K....K.....",
        "................",
        "................",
    ]

    // Eyes shut — flashed briefly for a blink.
    static let blink = [
        "................",
        ".....KKKKKK.....",
        "....KWWWWWWK....",
        "....KWKKKKWK....",
        "....KWWWWWWK....",
        ".....KKKKKK.....",
        ".......KK.......",
        "....KKKKKKKK....",
        ".......KK.......",
        ".......KK.......",
        ".......KK.......",
        "......K..K......",
        ".....K....K.....",
        ".....K....K.....",
        "................",
        "................",
    ]

    // Dance poses — cycled fast while Dude is showing off.
    static let danceA = [ // arms up in a Y, legs apart
        "................",
        ".....KKKKKK.....",
        "....KWWWWWWK....",
        "....KWEWWEWK....",
        "....KWWWWWWK....",
        ".....KKKKKK.....",
        "....K..KK..K....",
        ".....K.KK.K.....",
        ".......KK.......",
        ".......KK.......",
        ".......KK.......",
        "......K..K......",
        ".....K....K.....",
        "....K......K....",
        "................",
        "................",
    ]
    static let danceB = [ // arm out left, legs kicking left
        "................",
        ".....KKKKKK.....",
        "....KWWWWWWK....",
        "....KWEWWEWK....",
        "....KWWWWWWK....",
        ".....KKKKKK.....",
        ".......KK.......",
        "..KKKKKKKK......",
        ".......KK.......",
        ".......KK.......",
        ".......KK.......",
        ".....KK.K.......",
        "...KK...K.......",
        "..K.....K.......",
        "................",
        "................",
    ]
    static let danceC = [ // arm out right, legs kicking right
        "................",
        ".....KKKKKK.....",
        "....KWWWWWWK....",
        "....KWEWWEWK....",
        "....KWWWWWWK....",
        ".....KKKKKK.....",
        ".......KK.......",
        "......KKKKKKKK..",
        ".......KK.......",
        ".......KK.......",
        ".......KK.......",
        ".......K.KK.....",
        ".......K...KK...",
        ".......K.....K..",
        "................",
        "................",
    ]
    static let danceD = [ // arms tucked, big leg split
        "................",
        ".....KKKKKK.....",
        "....KWWWWWWK....",
        "....KWEWWEWK....",
        "....KWWWWWWK....",
        ".....KKKKKK.....",
        ".......KK.......",
        ".....KKKKKK.....",
        ".......KK.......",
        ".......KK.......",
        "......K..K......",
        ".....K....K.....",
        "....K......K....",
        "...K........K...",
        "................",
        "................",
    ]
    static let dance = [danceA, danceB, danceC, danceD]

    // Looking at your screen — leans in, hands cupped at his temples, eyes
    // focused. workingB shifts his gaze so he reads as scanning the screen.
    static let workingA = [
        "................",
        "................",
        ".....KKKKKK.....",
        "....KWWWWWWK....",
        "...KKWEWWEWKK...",
        "....KWWWWWWK....",
        ".....KKKKKK.....",
        ".......KK.......",
        "....KKKKKKKK....",
        ".......KK.......",
        ".......KK.......",
        "......K..K......",
        ".....K....K.....",
        ".....K....K.....",
        "................",
        "................",
    ]
    static let workingB = [
        "................",
        "................",
        ".....KKKKKK.....",
        "....KWWWWWWK....",
        "...KKEWWEWWKK...",
        "....KWWWWWWK....",
        ".....KKKKKK.....",
        ".......KK.......",
        "....KKKKKKKK....",
        ".......KK.......",
        ".......KK.......",
        "......K..K......",
        ".....K....K.....",
        ".....K....K.....",
        "................",
        "................",
    ]
    static let working = [workingA, workingB]

    // Listening — shown while you're typing to him. Idle stance plus a little
    // "incoming sound" chevron at his ear that pulses outward across frames.
    static let listenA = [
        "................",
        ".....KKKKKK.....",
        "..K.KWWWWWWK....",
        ".K..KWEWWEWK....",
        "..K.KWWWWWWK....",
        ".....KKKKKK.....",
        ".....KKKKKK.....",
        ".....K.KK.K.....",
        ".....K.KK.K.....",
        ".......KK.......",
        ".......KK.......",
        "......K..K......",
        ".....K....K.....",
        ".....K....K.....",
        "................",
        "................",
    ]
    static let listenB = [
        "................",
        ".....KKKKKK.....",
        ".K..KWWWWWWK....",
        "K...KWEWWEWK....",
        ".K..KWWWWWWK....",
        ".....KKKKKK.....",
        ".....KKKKKK.....",
        ".....K.KK.K.....",
        ".....K.KK.K.....",
        ".......KK.......",
        ".......KK.......",
        "......K..K......",
        ".....K....K.....",
        ".....K....K.....",
        "................",
        "................",
    ]
    static let listen = [listenA, listenB]

    // Voice mode — holding a microphone (accent-colored) up to his mouth. The
    // two frames open and close his mouth as if he's talking into it.
    static let voiceA = [
        "................",
        ".....KKKKKK.....",
        "....KWWWWWWK.AA.",
        "....KWEWWEWK.AA.",
        "....KWWKKWWK.A..",
        ".....KKKKKK..A..",
        ".......KK...A...",
        "....KKKKKKKKA...",
        ".......KK.......",
        ".......KK.......",
        ".......KK.......",
        "......K..K......",
        ".....K....K.....",
        ".....K....K.....",
        "................",
        "................",
    ]
    static let voiceB = [
        "................",
        ".....KKKKKK.....",
        "....KWWWWWWK.AA.",
        "....KWEWWEWK.AA.",
        "....KWWWWWWK.A..",
        ".....KKKKKK..A..",
        ".......KK...A...",
        "....KKKKKKKKA...",
        ".......KK.......",
        ".......KK.......",
        ".......KK.......",
        "......K..K......",
        ".....K....K.....",
        ".....K....K.....",
        "................",
        "................",
    ]
    static let voice = [voiceA, voiceB]

    // Walking — cycled while Dude strolls across the screen to an app's Dock
    // icon. Arms and legs swing in opposite phase; the panel itself slides, so
    // even a small stride reads as walking.
    static let walkA = [
        "................",
        ".....KKKKKK.....",
        "....KWWWWWWK....",
        "....KWEWWEWK....",
        "....KWWWWWWK....",
        ".....KKKKKK.....",
        ".....KKKKKK.....",
        "...KKK.KK.......",
        ".......KK.......",
        ".......KK.......",
        ".......KK.......",
        "......KK.K......",
        ".....K....KK....",
        ".....K.....K....",
        "................",
        "................",
    ]
    static let walkB = [
        "................",
        ".....KKKKKK.....",
        "....KWWWWWWK....",
        "....KWEWWEWK....",
        "....KWWWWWWK....",
        ".....KKKKKK.....",
        ".....KKKKKK.....",
        ".......KK.KKK...",
        ".......KK.......",
        ".......KK.......",
        ".......KK.......",
        "......K.KK......",
        "....KK....K.....",
        "....K.....K.....",
        "................",
        "................",
    ]
    static let walk = [walkA, walkB]

    // At the app — Dude crouches and pulls out his laptop (accent-colored
    // screen) to get to work. The two frames flicker the screen as if he's
    // typing away.
    static let laptopA = [
        "................",
        ".....KKKKKK.....",
        "....KWWWWWWK....",
        "....KWEWWEWK....",
        "....KWWWWWWK....",
        ".....KKKKKK.....",
        "......KK........",
        "....KKKKKK......",
        "...K......K.....",
        "..AAAAAAAAAA....",
        "..AAAAAAAAAA....",
        "..KKKKKKKKKK....",
        ".KKKKKKKKKKKK...",
        "...KK....KK.....",
        "................",
        "................",
    ]
    static let laptopB = [
        "................",
        ".....KKKKKK.....",
        "....KWWWWWWK....",
        "....KWEWWEWK....",
        "....KWWWWWWK....",
        ".....KKKKKK.....",
        "......KK........",
        "....KKKKKK......",
        "...K......K.....",
        "..AAAAAAAAAA....",
        "..AA.AA.AAA.....",
        "..KKKKKKKKKK....",
        ".KKKKKKKKKKKK...",
        "...KK....KK.....",
        "................",
        "................",
    ]
    static let laptop = [laptopA, laptopB]

    // Thinking — an animated "…" thought bubble over Dude's head, cycled while
    // he's actually chewing on your question (instead of saying "on it" and
    // going quiet). Three frames grow the dots.
    static let thinkA = [
        ".............K..",
        ".....KKKKKK.....",
        "....KWWWWWWK....",
        "....KWEWWEWK....",
        "....KWWWWWWK....",
        ".....KKKKKK.....",
        ".......KK.......",
        "....KKKKKKKK....",
        ".......KK.......",
        ".......KK.......",
        ".......KK.......",
        "......K..K......",
        ".....K....K.....",
        ".....K....K.....",
        "................",
        "................",
    ]
    static let thinkB = [
        "...........K.K..",
        ".....KKKKKK.....",
        "....KWWWWWWK....",
        "....KWEWWEWK....",
        "....KWWWWWWK....",
        ".....KKKKKK.....",
        ".......KK.......",
        "....KKKKKKKK....",
        ".......KK.......",
        ".......KK.......",
        ".......KK.......",
        "......K..K......",
        ".....K....K.....",
        ".....K....K.....",
        "................",
        "................",
    ]
    static let thinkC = [
        ".........K.K.K..",
        ".....KKKKKK.....",
        "....KWWWWWWK....",
        "....KWEWWEWK....",
        "....KWWWWWWK....",
        ".....KKKKKK.....",
        ".......KK.......",
        "....KKKKKKKK....",
        ".......KK.......",
        ".......KK.......",
        ".......KK.......",
        "......K..K......",
        ".....K....K.....",
        ".....K....K.....",
        "................",
        "................",
    ]
    static let think = [thinkA, thinkB, thinkC]

    // Victory! Both fists thrown up beside his head, mouth open in a grin —
    // cycled fast with a big hop for a triumphant fist-pump (e.g. right after
    // he beats an "I'm not a robot" checkbox). celebrateB tucks his legs up as
    // if mid-jump.
    static let celebrateA = [
        "...K........K...",
        "...K.KKKKKK.K...",
        "...KKWWWWWWKK...",
        "...KKWEWWEWKK...",
        "...KKWWKKWWKK...",
        ".....KKKKKK.....",
        ".....KKKKKK.....",
        ".....K.KK.K.....",
        ".....K.KK.K.....",
        ".......KK.......",
        ".......KK.......",
        "......K..K......",
        ".....K....K.....",
        ".....K....K.....",
        "................",
        "................",
    ]
    static let celebrateB = [
        "...K........K...",
        "...K.KKKKKK.K...",
        "...KKWWWWWWKK...",
        "...KKWEWWEWKK...",
        "...KKWWKKWWKK...",
        ".....KKKKKK.....",
        ".....KKKKKK.....",
        ".....K.KK.K.....",
        ".......KK.......",
        ".......KK.......",
        "......K..K......",
        "......K..K......",
        "................",
        "................",
        "................",
        "................",
    ]
    static let celebrate = [celebrateA, celebrateB]

    // Mouth open — cycled with idleA while Dude is "speaking".
    static let talk = [
        "................",
        ".....KKKKKK.....",
        "....KWWWWWWK....",
        "....KWEWWEWK....",
        "....KWWKKWWK....",
        ".....KKKKKK.....",
        ".......KK.......",
        "....KKKKKKKK....",
        ".......KK.......",
        ".......KK.......",
        ".......KK.......",
        "......K..K......",
        ".....K....K.....",
        ".....K....K.....",
        "................",
        "................",
    ]
}
