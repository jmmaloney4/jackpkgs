/**
 * Formats a resource name with standard prefix/suffix conventions.
 */
export function formatResourceName(
	project: string,
	environment: string,
	resource: string,
): string {
	return `${project}-${environment}-${resource}`.toLowerCase();
}

/**
 * Validates that a string is a valid GCP region.
 */
export function isValidGcpRegion(region: string): boolean {
	const validRegions = [
		"us-central1",
		"us-east1",
		"us-west1",
		"europe-west1",
		"asia-east1",
	];
	return validRegions.includes(region);
}

/**
 * Creates standard tags/labels for resources.
 */
export function createStandardLabels(
	project: string,
	environment: string,
	owner: string,
): Record<string, string> {
	return {
		project,
		environment,
		owner,
		"managed-by": "pulumi",
	};
}
