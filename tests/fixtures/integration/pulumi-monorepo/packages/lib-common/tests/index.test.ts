import { describe, expect, it } from "vitest";
import {
	createStandardLabels,
	formatResourceName,
	isValidGcpRegion,
} from "../src/index";

describe("formatResourceName", () => {
	it("formats name with project, environment, and resource", () => {
		expect(formatResourceName("myapp", "dev", "bucket")).toBe(
			"myapp-dev-bucket",
		);
	});

	it("lowercases", () => {
		expect(formatResourceName("MyApp", "DEV", "Bucket")).toBe(
			"myapp-dev-bucket",
		);
	});
});

describe("isValidGcpRegion", () => {
	it("returns true for valid regions", () => {
		expect(isValidGcpRegion("us-central1")).toBe(true);
		expect(isValidGcpRegion("europe-west1")).toBe(true);
	});

	it("returns false for invalid regions", () => {
		expect(isValidGcpRegion("invalid-region")).toBe(false);
		expect(isValidGcpRegion("")).toBe(false);
	});
});

describe("createStandardLabels", () => {
	it("creates labels with managed-by tag", () => {
		const labels = createStandardLabels("myapp", "prod", "team-infra");
		expect(labels).toEqual({
			project: "myapp",
			environment: "prod",
			owner: "team-infra",
			"managed-by": "pulumi",
		});
	});
});
