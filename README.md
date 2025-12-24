# Azure Reserved Capacity

A repository for testing and managing Azure Reserved Capacity implementations.

## Overview

This project provides tools and scripts to help manage Azure Reserved Capacity, allowing you to optimize costs by reserving Azure resources in advance.

## Prerequisites

- Azure subscription
- Azure service principal with appropriate permissions
- GitHub repository secrets and variables configured

## Configuration

Configure your Azure credentials and subscription settings before running scripts.

### Required GitHub Secrets

Configure the following secrets in your repository settings (`Settings > Secrets and variables > Actions`):

- `AZURE_CLIENT_SECRET` - Azure service principal client secret

### Required GitHub Variables

Configure the following variables if needed:

- `AZURE_LOGIN` - Azure service principal client ID
- `AZURE_TENANT_ID` - Azure AD tenant ID

## Running the Workflow

### Manually Trigger the Workflow

1. Navigate to the **Actions** tab in your GitHub repository
2. Select the workflow you want to run from the left sidebar
3. Click the **Run workflow** button
4. Select the branch you want to run the workflow from
5. Fill in any required input parameters
6. Click **Run workflow** to start the execution

## Contact

For questions or support, please open an issue in this repository.
