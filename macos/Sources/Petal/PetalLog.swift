import os

/// Petal's own log (`petal logs` and Check Petal read this subsystem). Only Petal's own words go in it, never a
/// title, an address, a file's name or anything the person wrote.
enum PetalLog {
    static let notes = Logger(subsystem: "tech.edgetr.petal", category: "notes")
}
