import * as gcp from "@pulumi/gcp";
import * as pulumi from "@pulumi/pulumi";
import { createStandardLabels, formatResourceName } from "@test/lib-common";
import { getConfig } from "@test/lib-pulumi";

// Stack configuration
const project = getConfig("project", "test-project");
const environment = "dev";
const owner = getConfig("owner", "test-owner");
const region = getConfig("region", "us-central1");

// Standard labels for all resources
const labels = createStandardLabels(project, environment, owner);

// Example: Create a GCS bucket with standard naming
const bucketName = formatResourceName(project, environment, "data");
const dataBucket = new gcp.storage.Bucket(bucketName, {
	name: bucketName,
	location: region,
	labels,
	uniformBucketLevelAccess: true,
	versioning: {
		enabled: true,
	},
});

// Export bucket URL
export const bucketUrl = pulumi.interpolate`gs://${dataBucket.name}`;
export const bucketSelfLink = dataBucket.selfLink;
