import isNumber from "is-number";

export function double(n) {
  if (!isNumber(n)) throw new Error("not a number");
  return n * 2;
}
