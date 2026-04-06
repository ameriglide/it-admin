import { randomInt } from "crypto";

const WORDS = [
  "apple", "arrow", "badge", "baker", "beach", "blade", "blaze", "bloom",
  "board", "bonus", "brave", "brick", "brush", "cabin", "candy", "cargo",
  "cedar", "chain", "chalk", "chart", "chess", "chief", "chord", "civic",
  "claim", "clash", "clay", "cliff", "climb", "clock", "cloud", "coach",
  "coast", "coral", "craft", "crane", "creek", "crisp", "crown", "crush",
  "curve", "dairy", "dance", "delta", "depot", "derby", "disco", "dodge",
  "draft", "drain", "dream", "drift", "drive", "drone", "drums", "eagle",
  "earth", "ember", "equal", "event", "fable", "fairy", "feast", "fence",
  "fiber", "field", "final", "flame", "flash", "flask", "fleet", "flint",
  "float", "flood", "flora", "flute", "focal", "forge", "forum", "frost",
  "fruit", "gamma", "gauge", "genre", "ghost", "giant", "glade", "glass",
  "gleam", "globe", "glove", "grain", "grand", "grape", "grasp", "green",
  "grove", "guard", "guide", "haven", "heart", "hedge", "herbs", "heron",
  "honey", "horse", "house", "humor", "ivory", "jewel", "joint", "judge",
  "juice", "kayak", "knack", "kneel", "knife", "lance", "latch", "layer",
  "lemon", "level", "light", "lilac", "linen", "lodge", "lunar", "lyric",
  "magic", "manor", "maple", "march", "marsh", "medal", "melon", "mercy",
  "metal", "minor", "mixer", "model", "money", "moose", "mound", "music",
  "nerve", "noble", "north", "novel", "ocean", "olive", "opera", "orbit",
  "organ", "otter", "outer", "oxide", "ozone", "paint", "panel", "paper",
  "paste", "patch", "pearl", "penny", "perch", "pilot", "pinch", "pixel",
  "pizza", "plain", "plane", "plant", "plaza", "plume", "plumb", "polar",
  "poppy", "power", "press", "pride", "prism", "prize", "proof", "prose",
  "pulse", "punch", "quest", "quick", "quiet", "quilt", "quota", "radar",
  "ranch", "raven", "realm", "reign", "relay", "ridge", "rival", "river",
  "robin", "rocky", "rouge", "round", "royal", "ruby", "ruler", "saint",
  "salad", "scale", "scene", "scout", "seven", "shade", "shark", "sharp",
  "sheep", "shelf", "shell", "shift", "shirt", "shore", "shown", "sight",
  "silky", "slate", "slice", "slope", "smart", "smith", "smoke", "snake",
  "solar", "solid", "sonic", "south", "space", "spark", "spear", "spice",
  "spike", "spine", "spoke", "squad", "staff", "stage", "stake", "stamp",
  "stand", "stare", "stark", "start", "steam", "steel", "steep", "stern",
  "stock", "stone", "storm", "stove", "strap", "straw", "strip", "sugar",
  "surge", "swamp", "sweet", "swept", "swift", "sword", "table", "thorn",
  "tiger", "timer", "toast", "topaz", "torch", "total", "tower", "trace",
  "track", "trade", "trail", "train", "trait", "trend", "trial", "tribe",
  "trick", "trout", "trunk", "trust", "tulip", "tuner", "ultra", "unity",
  "upper", "urban", "valid", "valor", "vault", "verse", "vigor", "vinyl",
  "viola", "vivid", "vocal", "voice", "wagon", "watch", "water", "whale",
  "wheat", "wheel", "white", "width", "world", "wrist", "yacht", "youth",
  "zebra", "bloom", "bluff", "briar", "cairn", "cider", "cloak", "creed",
  "ember", "haven", "ivory", "lotus", "oasis", "plaid", "quest", "relic",
  "sable", "talon", "umbra", "vista", "whelk", "xenon", "arbor", "basin",
];

export function generateTempPassword(): string {
  const picked: string[] = [];
  while (picked.length < 4) {
    const word = WORDS[randomInt(WORDS.length)];
    if (!picked.includes(word)) {
      picked.push(word[0].toUpperCase() + word.slice(1));
    }
  }
  return picked.join("-");
}

const UPPER = "ABCDEFGHIJKLMNOPQRSTUVWXYZ";
const LOWER = "abcdefghijklmnopqrstuvwxyz";
const DIGITS = "0123456789";
const ALL = UPPER + LOWER + DIGITS;

export function generateSipPassword(): string {
  let pw: string;
  do {
    pw = Array.from({ length: 16 }, () => ALL[randomInt(ALL.length)]).join("");
  } while (!/[A-Z]/.test(pw) || !/[a-z]/.test(pw) || !/[0-9]/.test(pw));
  return pw;
}
