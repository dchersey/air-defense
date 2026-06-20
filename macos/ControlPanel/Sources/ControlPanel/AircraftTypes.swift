import Foundation

/// Translates ICAO aircraft **type designators** (DOC 8643 — what the ADS-B feed
/// reports, e.g. "B738") into a human-readable name ("Boeing 737-800") for the
/// recent-flights hover tooltip. A small curated table covering the traffic that
/// actually shows up over a US metro airport (narrowbodies, regional jets, common
/// widebodies + a few bizjets/turboprops); unknown codes fall back to the raw code.
enum AircraftTypes {
  /// Friendly name for an ICAO type code, or nil if we don't recognise it.
  static func name(for code: String) -> String? {
    map[code.uppercased().trimmingCharacters(in: .whitespaces)]
  }

  private static let map: [String: String] = [
    // Airbus narrowbody
    "A318": "Airbus A318", "A319": "Airbus A319", "A320": "Airbus A320",
    "A321": "Airbus A321",
    "A19N": "Airbus A319neo", "A20N": "Airbus A320neo", "A21N": "Airbus A321neo",
    // Airbus A220 (ex-Bombardier C Series)
    "BCS1": "Airbus A220-100", "BCS3": "Airbus A220-300",
    // Airbus widebody
    "A306": "Airbus A300-600", "A310": "Airbus A310",
    "A332": "Airbus A330-200", "A333": "Airbus A330-300",
    "A338": "Airbus A330-800neo", "A339": "Airbus A330-900neo",
    "A342": "Airbus A340-200", "A343": "Airbus A340-300", "A346": "Airbus A340-600",
    "A359": "Airbus A350-900", "A35K": "Airbus A350-1000",
    "A388": "Airbus A380-800",
    // Boeing 737
    "B731": "Boeing 737-100", "B732": "Boeing 737-200", "B733": "Boeing 737-300",
    "B734": "Boeing 737-400", "B735": "Boeing 737-500", "B736": "Boeing 737-600",
    "B737": "Boeing 737-700", "B738": "Boeing 737-800", "B739": "Boeing 737-900",
    "B37M": "Boeing 737 MAX 7", "B38M": "Boeing 737 MAX 8",
    "B39M": "Boeing 737 MAX 9", "B3XM": "Boeing 737 MAX 10",
    // Boeing 757/767/777/787/747
    "B752": "Boeing 757-200", "B753": "Boeing 757-300",
    "B762": "Boeing 767-200", "B763": "Boeing 767-300", "B764": "Boeing 767-400",
    "B772": "Boeing 777-200", "B77L": "Boeing 777-200LR", "B77W": "Boeing 777-300ER",
    "B778": "Boeing 777-8", "B779": "Boeing 777-9",
    "B788": "Boeing 787-8", "B789": "Boeing 787-9", "B78X": "Boeing 787-10",
    "B742": "Boeing 747-200", "B744": "Boeing 747-400", "B748": "Boeing 747-8",
    // Embraer
    "E135": "Embraer ERJ-135", "E145": "Embraer ERJ-145",
    "E170": "Embraer E170", "E75S": "Embraer E175", "E75L": "Embraer E175",
    "E190": "Embraer E190", "E195": "Embraer E195",
    "E290": "Embraer E190-E2", "E295": "Embraer E195-E2",
    "E50P": "Embraer Phenom 100", "E55P": "Embraer Phenom 300",
    // Bombardier CRJ + Dash 8
    "CRJ1": "Bombardier CRJ-100", "CRJ2": "Bombardier CRJ-200",
    "CRJ7": "Bombardier CRJ-700", "CRJ9": "Bombardier CRJ-900",
    "CRJX": "Bombardier CRJ-1000",
    "DH8A": "Bombardier Dash 8-100", "DH8C": "Bombardier Dash 8-300",
    "DH8D": "Bombardier Dash 8 Q400",
    // McDonnell Douglas
    "MD11": "McDonnell Douglas MD-11", "MD82": "McDonnell Douglas MD-82",
    "MD83": "McDonnell Douglas MD-83", "MD88": "McDonnell Douglas MD-88",
    "MD90": "McDonnell Douglas MD-90",
    // ATR / regional turboprops
    "AT43": "ATR 42-300", "AT45": "ATR 42-500", "AT72": "ATR 72",
    "AT75": "ATR 72-500", "AT76": "ATR 72-600",
    "SF34": "Saab 340", "SW4": "Fairchild Metroliner",
    // Common GA / business jets / turboprops
    "C208": "Cessna 208 Caravan", "C25A": "Cessna Citation CJ2",
    "C56X": "Cessna Citation Excel", "C68A": "Cessna Citation Latitude",
    "C750": "Cessna Citation X",
    "PC12": "Pilatus PC-12", "PC24": "Pilatus PC-24",
    "TBM9": "Daher TBM 900", "BE20": "Beechcraft King Air 200",
    "GLF4": "Gulfstream IV", "GLF5": "Gulfstream V", "GLF6": "Gulfstream G650",
    "GL7T": "Gulfstream G700",
    "CL35": "Bombardier Challenger 350", "CL60": "Bombardier Challenger 600",
    "GLEX": "Bombardier Global Express",
    "LJ45": "Learjet 45", "LJ60": "Learjet 60",
    "F2TH": "Dassault Falcon 2000", "FA7X": "Dassault Falcon 7X",
    "H25B": "Hawker 800",
  ]
}
