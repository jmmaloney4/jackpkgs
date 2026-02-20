import { describe, expect, it } from "vitest";
import { add, multiply } from "./index.js";

describe("math utilities", () => {
	it("adds two numbers", () => {
		expect(add(1, 2)).toBe(3);
	});

	it("multiplies two numbers", () => {
		expect(multiply(3, 4)).toBe(12);
	});
});
