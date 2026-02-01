import type * as pulumi from "@pulumi/pulumi";
import { describe, expect, it, vi } from "vitest";

// Mock Pulumi runtime before importing our modules
vi.mock("@pulumi/pulumi", async () => {
	const actual = await vi.importActual("@pulumi/pulumi");
	return {
		...actual,
		// Mock runtime to avoid actual Pulumi engine dependency
		runtime: {
			...((actual as any).runtime || {}),
			setMocks: vi.fn(),
			setAllConfig: vi.fn(),
		},
		// Mock Output to be synchronous for testing
		output: <T>(val: T) => ({
			apply: <U>(fn: (v: T) => U) => ({ value: fn(val) }),
			value: val,
		}),
		// Mock Config
		Config: vi.fn().mockImplementation(() => ({
			get: vi.fn().mockReturnValue(undefined),
			require: vi.fn().mockImplementation((key: string) => {
				throw new Error(`Missing required config: ${key}`);
			}),
		})),
		// Mock ComponentResource
		ComponentResource: class MockComponentResource {
			constructor(
				public readonly __type: string,
				public readonly __name: string,
				_args: any,
				_opts?: any,
			) {}
			registerOutputs(_outputs?: any) {}
		},
	};
});

// Now import our code (after mocks are set up)
import {
	getConfig,
	requireConfig,
	StandardComponent,
	type StandardResourceArgs,
} from "../src/index";

// Concrete implementation for testing
class TestComponent extends StandardComponent {
	constructor(
		name: string,
		args: StandardResourceArgs,
		opts?: pulumi.ComponentResourceOptions,
	) {
		super("test:TestComponent", name, args, opts);
	}

	public getChildNameForTest(suffix: string) {
		return this.childName(suffix);
	}
}

describe("StandardComponent", () => {
	it("creates name prefix from project, environment, and name", () => {
		const component = new TestComponent("mybucket", {
			project: "myapp",
			environment: "dev",
			owner: "team-infra",
		});

		// Access mocked output value
		expect((component.namePrefix as any).value).toBe("myapp-dev-mybucket");
	});

	it("creates standard labels with managed-by tag", () => {
		const component = new TestComponent("mybucket", {
			project: "myapp",
			environment: "prod",
			owner: "team-platform",
		});

		expect((component.labels as any).value).toEqual({
			project: "myapp",
			environment: "prod",
			owner: "team-platform",
			"managed-by": "pulumi",
		});
	});

	it("generates child names with suffix", () => {
		const component = new TestComponent("myservice", {
			project: "app",
			environment: "staging",
			owner: "ops",
		});

		const childName = component.getChildNameForTest("logs");
		expect(childName.value).toBe("app-staging-myservice-logs");
	});
});

describe("getConfig", () => {
	it("returns default value when config key is not set", () => {
		const result = getConfig("nonexistent", "default-value");
		expect(result).toBe("default-value");
	});
});

describe("requireConfig", () => {
	it("throws when required config is missing", () => {
		expect(() => requireConfig("missing-key")).toThrow(
			"Missing required config",
		);
	});
});
