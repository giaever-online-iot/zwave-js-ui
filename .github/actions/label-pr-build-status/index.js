const core = require('@actions/core');
const github = require('@actions/github');
const fs = require('fs');
const path = require('path');

const labelMeta = {
  'build/passed': { color: '0e8a16', description: 'All builds passed' },
  'build/failed': { color: 'b60205', description: 'One or more builds failed' },
  'build/unknown': { color: 'f9c513', description: 'One or more builds unknown' },
};

async function run() {
  try {
    const token = core.getInput('github-token', { required: true });
    const prNumber = core.getInput('pr-number', { required: true });
    const artifactsPath = core.getInput('artifacts-path', { required: true });

    const octokit = github.getOctokit(token);
    const { owner, repo } = github.context.repo;

    core.info(`Checking artifacts in: ${artifactsPath}`);

    // Check for snap and log files
    const hasSnapFiles = checkForFiles(artifactsPath, '.snap');
    const hasLogFiles = checkForFiles(artifactsPath, '.log');

    core.info(`Snap files found: ${hasSnapFiles}`);
    core.info(`Log files found: ${hasLogFiles}`);

    // Determine the label based on file presence
    let labelToAdd;
    if (!hasSnapFiles) {
      labelToAdd = 'build/failed';
    } else if (!hasLogFiles) {
      labelToAdd = 'build/unknown';
    } else {
      labelToAdd = 'build/passed';
    }

    core.info(`Label to add: ${labelToAdd}`);

    // Ensure the label exists in the repository
    await ensureLabelExists(octokit, owner, repo, labelToAdd);

    // Remove other build status labels
    const labelsToRemove = Object.keys(labelMeta).filter(l => l !== labelToAdd);
    for (const label of labelsToRemove) {
      try {
        await octokit.rest.issues.removeLabel({
          owner,
          repo,
          issue_number: prNumber,
          name: label,
        });
        core.info(`Removed label: ${label}`);
      } catch (error) {
        // Ignore if label doesn't exist
        if (error.status !== 404) {
          core.warning(`Failed to remove label ${label}: ${error.message}`);
        }
      }
    }

    // Add the new label
    await octokit.rest.issues.addLabels({
      owner,
      repo,
      issue_number: prNumber,
      labels: [labelToAdd],
    });

    core.info(`Added label: ${labelToAdd}`);
    core.setOutput('label', labelToAdd);
  } catch (error) {
    core.setFailed(error.message);
  }
}

function checkForFiles(dirPath, extension) {
  try {
    if (!fs.existsSync(dirPath)) {
      return false;
    }

    const files = walkDir(dirPath);
    return files.some(file => file.endsWith(extension));
  } catch (error) {
    core.warning(`Error checking for ${extension} files: ${error.message}`);
    return false;
  }
}

function walkDir(dir) {
  let files = [];
  const items = fs.readdirSync(dir);

  for (const item of items) {
    const fullPath = path.join(dir, item);
    const stat = fs.statSync(fullPath);

    if (stat.isDirectory()) {
      files = files.concat(walkDir(fullPath));
    } else {
      files.push(fullPath);
    }
  }

  return files;
}

async function ensureLabelExists(octokit, owner, repo, labelName) {
  try {
    await octokit.rest.issues.getLabel({
      owner,
      repo,
      name: labelName,
    });
  } catch (error) {
    if (error.status === 404) {
      // Label doesn't exist, create it
      const labelInfo = labelMeta[labelName];
      await octokit.rest.issues.createLabel({
        owner,
        repo,
        name: labelName,
        color: labelInfo.color,
        description: labelInfo.description,
      });
      core.info(`Created label: ${labelName}`);
    } else {
      throw error;
    }
  }
}

run();
