/**
 * Layer 0: the Finnish bank barcode (virtuaaliviivakoodi).
 *
 * A 54-digit Code 128 barcode printed on most Finnish bills, encoding the
 * payee's IBAN, the amount, the reference number and the due date. Reading it
 * is free, offline, instant and exact -- so where it is present it is
 * authoritative, and the model is never asked to guess a value we can simply
 * read.
 *
 * Layout (both versions are 54 digits):
 *
 *   v4  version(1) iban(16) euros(6) cents(2) reserve(3) reference(20) date(6)
 *   v5  version(1) iban(16) euros(6) cents(2) rfCheck(2) reference(21) date(6)
 *
 * Version 4 carries a Finnish viitenumero; version 5 carries an RF creditor
 * reference (ISO 11649).
 *
 * NOTE: verify these offsets against Finanssiala's "Pankkiviivakoodi-opas"
 * before trusting this in production. The structure is stable and widely
 * documented, but it is a published specification and this is a transcription
 * of it -- the tests below encode the behaviour, not the authority.
 */

import type { BarcodeFacts } from "../../domain/contracts.ts";

export type ReferenceKind = "finnish" | "rf";

export interface FinnishBarcode extends BarcodeFacts {
  version: 4 | 5;
  referenceKind: ReferenceKind;
}

/** ISO 13616 mod-97 check, done in chunks so no bignum is needed. */
function mod97(input: string): number {
  let remainder = 0;
  for (const ch of input) {
    const code = ch.charCodeAt(0);
    let piece: string;
    if (code >= 65 && code <= 90) {
      piece = String(code - 55); // A=10 ... Z=35
    } else if (code >= 48 && code <= 57) {
      piece = ch;
    } else {
      return -1; // anything else invalidates the check
    }
    for (const d of piece) {
      remainder = (remainder * 10 + Number(d)) % 97;
    }
  }
  return remainder;
}

export function isValidIban(iban: string): boolean {
  const s = iban.replace(/\s+/g, "").toUpperCase();
  if (!/^[A-Z]{2}[0-9A-Z]{13,32}$/.test(s)) return false;
  return mod97(s.slice(4) + s.slice(0, 4)) === 1;
}

/**
 * Finnish viitenumero: the last digit is a 7-3-1 weighted check digit over the
 * preceding digits, read from the right.
 */
export function isValidFinnishReference(reference: string): boolean {
  const s = reference.replace(/\s+/g, "");
  if (!/^\d{4,20}$/.test(s)) return false;
  const body = s.slice(0, -1);
  const check = Number(s.slice(-1));
  const weights = [7, 3, 1];
  let sum = 0;
  for (let i = 0; i < body.length; i++) {
    const digit = Number(body[body.length - 1 - i]);
    sum += digit * weights[i % 3];
  }
  return (10 - (sum % 10)) % 10 === check;
}

/** ISO 11649 RF reference: mod-97 over reference + "RF00" must equal 1. */
export function isValidRfReference(reference: string): boolean {
  const s = reference.replace(/\s+/g, "").toUpperCase();
  if (!/^RF\d{2}[0-9A-Z]{1,21}$/.test(s)) return false;
  return mod97(s.slice(4) + s.slice(0, 4)) === 1;
}

function parseDueDate(yymmdd: string): string | null {
  if (yymmdd === "000000") return null;
  const year = 2000 + Number(yymmdd.slice(0, 2));
  const month = Number(yymmdd.slice(2, 4));
  const day = Number(yymmdd.slice(4, 6));
  if (month < 1 || month > 12 || day < 1 || day > 31) return null;
  const iso = `${year}-${String(month).padStart(2, "0")}-${String(day).padStart(2, "0")}`;
  // Reject dates the calendar does not have, e.g. 31 February.
  const parsed = new Date(`${iso}T00:00:00Z`);
  if (Number.isNaN(parsed.getTime()) || parsed.getUTCDate() !== day) return null;
  return iso;
}

/**
 * Parse a scanned barcode payload. Returns null when the payload is not a
 * Finnish bank barcode at all -- the caller then simply proceeds without
 * layer 0, which is the normal case for letters rather than bills.
 */
export function parseFinnishBarcode(raw: string): FinnishBarcode | null {
  const s = raw.replace(/\s+/g, "");
  if (!/^\d{54}$/.test(s)) return null;

  const version = Number(s[0]);
  if (version !== 4 && version !== 5) return null;

  const iban = "FI" + s.slice(1, 17);
  const amountCents = Number(s.slice(17, 23)) * 100 + Number(s.slice(23, 25));

  let reference: string;
  let referenceKind: ReferenceKind;
  if (version === 4) {
    // 3 reserve digits, then a 20-digit zero-padded viitenumero.
    reference = s.slice(28, 48).replace(/^0+/, "");
    referenceKind = "finnish";
  } else {
    // 2 RF check digits, then a 21-digit zero-padded reference.
    reference = "RF" + s.slice(25, 27) + s.slice(27, 48).replace(/^0+/, "");
    referenceKind = "rf";
  }

  const dueDate = parseDueDate(s.slice(48, 54));

  return {
    version: version as 4 | 5,
    iban,
    amountCents,
    reference,
    referenceKind,
    dueDate,
    ibanValid: isValidIban(iban),
    referenceValid: referenceKind === "finnish"
      ? isValidFinnishReference(reference)
      : isValidRfReference(reference),
  };
}
