# ADSGroupPolicyDSCv3

![DSC Active Directory GPO](./image/gpo-as-code-dscv3.png)


This repository contains PowerShell DSC v3 resources for managing Active Directory Group Policy objects and settings.

## Repository Description

The resources in this project are focused on Group Policy management scenarios, including:

- GPO creation and configuration
- Group Policy links (GPLink)
- Group Policy registry settings
- Group Policy Preferences registry values

The main DSC v3 resources are located in the `resources` folder:

- `GPO`
- `GPLink`
- `GPRegistryValue`
- `GPPrefRegistryValue`

## Requirements and Dependencies

These DSC v3 resources depend on Windows Group Policy management components.

To use them, the target system must have the required Windows features and RSAT tools installed for Group Policy management (for example, Group Policy Management Console and related Group Policy cmdlets).

If the required Windows Feature/RSAT components are missing, resource operations that manage Group Policy may fail.

1. Windows 11 (Client OS)On Windows 11, RSAT is managed via Features on Demand (Capabilities) using the DISM module.  
Install Group Policy Management Tools:PowerShell  
```powershell
Add-WindowsCapability -Online -Name "Rsat.GroupPolicy.Management.Tools~~~~0.0.1.0"
```
Verify Installation:PowerShell  
```powershell
Get-WindowsCapability -Online -Name "Rsat.GroupPolicy.Management.Tools*"  
```


2. Windows Server (Server OS)On Windows Server (e.g., Windows Server 2016 / 2019 / 2022 / 2025), Group Policy Management is an OS Feature managed via the Server Manager module.  
Install Group Policy Management Feature:PowerShell  
```powershell
Install-WindowsFeature -Name GPMC -IncludeManagementTools
```
Verify Installation:PowerShell  

```powershell
Get-WindowsFeature -Name GPMC
```
