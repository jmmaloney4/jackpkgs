import isOdd from "is-odd";
import { double } from "@test/lib";

const n = 3;
const result = isOdd(n) && double(n) === 6 ? "pass" : "fail";
console.log(result);
