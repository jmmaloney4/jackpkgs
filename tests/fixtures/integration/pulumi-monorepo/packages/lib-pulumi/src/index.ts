import * as pulumi from "@pulumi/pulumi";
import { createStandardLabels, formatResourceName } from "@test/lib-common";

export interface StandardResourceArgs {
	project: string;
	environment: string;
	owner: string;
	region?: string;
}

/**
 * A component resource that provides standard naming and labeling.
 * This is a base class for creating standardized infrastructure components.
 */
export abstract class StandardComponent extends pulumi.ComponentResource {
	public readonly labels: pulumi.Output<Record<string, string>>;
	public readonly namePrefix: pulumi.Output<string>;

	constructor(
		type: string,
		name: string,
		args: StandardResourceArgs,
		opts?: pulumi.ComponentResourceOptions,
	) {
		super(type, name, {}, opts);

		this.namePrefix = pulumi.output(
			formatResourceName(args.project, args.environment, name),
		);

		this.labels = pulumi.output(
			createStandardLabels(args.project, args.environment, args.owner),
		);
	}

	/**
	 * Helper to create a child resource name.
	 */
	protected childName(suffix: string): pulumi.Output<string> {
		return this.namePrefix.apply((prefix) => `${prefix}-${suffix}`);
	}
}

/**
 * Configuration helper that reads from Pulumi config with defaults.
 */
export function getConfig<T>(key: string, defaultValue: T): T {
	const config = new pulumi.Config();
	return (config.get(key) as T) ?? defaultValue;
}

/**
 * Validates that required config keys are present.
 */
export function requireConfig(...keys: string[]): Record<string, string> {
	const config = new pulumi.Config();
	const result: Record<string, string> = {};

	for (const key of keys) {
		result[key] = config.require(key);
	}

	return result;
}
