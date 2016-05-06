#
# CompressAndCycle.ps1
#

### Clear existing errors to get a clean tally and to catch any configuration errors
$Error.clear()

New-Module -ScriptBlock {

  ### =====================================================================================
  ### IMPORT REQUIRED MODULES
  ### =====================================================================================
  $required_modules = @(
    "C:\Users\matthew.johnson\Source\Repos\7-Zip-PSM\7-Zip PSM\7-Zip.psm1"
  )

  $module_search_paths = @(
    $PSScriptRoot,
    (Get-Item ($PSScriptRoot + "\..\..\7-Zip-PSM\7-Zip PSM")).FullName
  )

  $Env:PSModulePath = ($module_search_paths -join ";") + ";" + $Env:PSModulePath

  $required_modules | % {
    try {
      Import-Module "$_" -ErrorAction Stop
    } catch {
      throw [System.IO.FileNotFoundException] "Unable to locate the required module, $_"
    }
  }

  ### =====================================================================================
  ### CONFIGURE COMMON MODULE COMPONENTS
  ### =====================================================================================

  ## GROUPING FUNCTIONS

  ## Note: the items are passed to the grouping functions individually (they are not processed
  ## as part of a collection).

  ## A GroupingState property is added to the object $_ with the following hashtable keys:
  ##  items := a reference to the full items array being processed
  ##  current_index := the index of the current item in the set being processed
  ##  last_index := the index of the last item in the set being processed
  ##  is_first_item := is true if the current_index == 0
  ##  is_last_item := is true if the current_index == last_index
  ##  default_tag := the default name to be used if no other value can be derieved.
  ##    Note: This value is not used automatically - it's for reference purposes and must be 
  ##    explicitly utilized
  ##  last_tag := the last value that was sent on down the pipe - initially the default_tag
  ##  tag := defaults to null, provide a string value to specify the group this item should
  ##    belong to. Null values will result in the item being dropped (not grouped).

  $grouping_functions = @{
    None = { $_.GroupingState.tag = $_.Name; $_ };
    ByDay = { $_.GroupingState.tag = [Convert]::ToString($_.CreationTime.DayofYear) + [Convert]::ToString($_.CreationTime.DayofYear); $_ };
    BySQLFulls = { if ($_.Extension -like ".bak") { $_.GroupingState.tag = $_.Name } else { $_.GroupingState.tag = $_.GroupingState.last_tag } $_ };
  }

  $naming_functions = @{
    "FirstItemInGroup" = { if ($_.GroupingState.is_first_item) { $_.GroupingState.tag = $_.Name } else { $_.GroupingState.tag = $_.GroupingState.last_tag } $_ };

    "LastItemInGroup" = { $_.GroupingState.tag = $_.GroupingState.items[$_.GroupingState.last_index].Name; $_ };

    "Parent+CreatedDateByMinute" = {
      $_.GroupingState.tag = (Split-Path $_.FullName -Parent).Split("\")[-1] + " " + $_.CreationTime.ToString("yyyy.MM.dd HHmm00")
      $_
    };

    "Parent+CreatedDateByHour" = { 
      $_.GroupingState.tag = (Split-Path $_.FullName -Parent).Split("\")[-1] + " " + $_.CreationTime.ToString("yyyy.MM.dd HH0000")
      $_
    };

    "Parent+CreatedDateByDay" = {
      $_.GroupingState.tag = (Split-Path $_.FullName -Parent).Split("\")[-1] + " " + $_.CreationTime.ToString("yyyy.MM.dd")
      $_
    };

    "Parent+ModifiedDateByMinute" = { 
      $_.GroupingState.tag = (Split-Path $_.FullName -Parent).Split("\")[-1] + " " + $_.LastWriteTime.ToString("yyyy.MM.dd HHmm00")
      $_
    };

    "Parent+ModifiedDateByHour" = {
      $_.GroupingState.tag = (Split-Path $_.FullName -Parent).Split("\")[-1] + " " + $_.LastWriteTime.ToString("yyyy.MM.dd HH0000")
      $_
    };

    "Parent+ModifiedDateByDay" = { 
      $_.GroupingState.tag = (Split-Path $_.FullName -Parent).Split("\")[-1] + " " + $_.LastWriteTime.ToString("yyyy.MM.dd")
      $_
    };
  }

  $common_task_parameters = @(
    @{
      Name = "Path";
      Type = ([string]);
      Mandatory = $true;
      Position = 0;
      ValueFromPipeline = $false;
      ValueFromPipelineByPropertyName = $true;
      HelpMessage = "The base path containing items to be processed";
    },
    @{
      Name = "ItemGroupingMethod";
      Type = ([string]);
      Mandatory = $true;
      Position = 5;
      ValueFromPipeline = $false;
      ValueFromPipelineByPropertyName = $true;
      HelpMessage = "Define how items will be grouped (by 'Day' for example)";
      ValidateSet = $grouping_functions.Keys;
    },
    @{
      Name = "Include";
      Type = ([regex]);
      Mandatory = $false;
      Position = 10;
      ValueFromPipeline = $false;
      ValueFromPipelineByPropertyName = $true;
      Default = [regex]'.*'; # Default, include everything
    },
    @{
      Name = "Exclude";
      Type = ([regex]);
      Mandatory = $false;
      Position = 15;
      ValueFromPipeline = $false;
      ValueFromPipelineByPropertyName = $true;
      Default = [regex]'(?!)'; #Default, exclude nothing
    },
    @{
      Name = "UnactionableTimespan";
      Type = ([timespan]);
      Mandatory = $false;
      Position = 20;
      ValueFromPipeline = $false;
      ValueFromPipelineByPropertyName = $true;
      Default = New-Object System.TimeSpan(0,0,0,0);
    },
    @{
      Name = "Recurse";
      Type = ([switch]);
      ValueFromPipeline = $false;
      ValueFromPipelineByPropertyName = $true;
      Default = [switch]$false;
    },
    @{
      Name = "WhatIf";
      Type = ([switch]);
      ValueFromPipeline = $false;
      ValueFromPipelineByPropertyName = $true;
      Default = [switch]$false;
    }
  )

  function script:group_items_backup {
    Param(
      [object[]]$items,
      [scriptblock[]]$grouping_functions,
      [int]$starting_index = 0,
      [string]$default_group_name = "Orphan"
    )

    $groups = @{}

    $group_name = $default_group_name

    $grouping_state = @{
      current_index = 0;
      last_index = $items.Count - 1;
      default_group_name = $default_group_name;
      last_group_name = $group_name;
    }

    $items | % {

      Add-Member -InputObject $_ -MemberType NoteProperty -Name GroupingState -Value $grouping_state
      
      ## Run the item through the specified grouping function and see if a new tag is returned
      $temp_group_name = $_ | % $grouping_functions[$starting_index]

      ## If the grouping function returned a non-null value, update the group name.
      ## If the grouping function returned a null, the last value returned is in force
      if ($temp_group_name -ne $null) {
        $group_name = $temp_group_name
      }

      ## Make sure the group name is associated with an array in the 'groups' hashtable
      if ($groups.Keys -notcontains $group_name) {
        $groups[$group_name] = @()
      }

      ## Decorate the object with a new property indicating how the items has been tagged
      if ($_.PSObject.Properties.name -notcontains "GroupTag") {
        
        ## If the item has not already been decorated, add a new member
        Add-Member -InputObject $_ -MemberType NoteProperty -Name GroupTags -Value @($group_name)
      
      } else {
        
        ## If the item has already been grouped, add to the existing list of tags
        $_.GroupTags += $group_name
      
      }

      ## Remove the grouping state decorator as we don't need it any more
      $_.PSObject.Properties.Remove('GroupingState')

      ## Update the original grouping state reference for the next iterations
      $grouping_state['current_index'] += 1
      $grouping_state['last_group_name'] = $group_name

      ## Finally, add our item to the hashtable of groups
      $groups[$group_name] +=  $_
    }

    ## If multiple grouping functions are provided, recurse
    if (($starting_index + 1) -lt $grouping_functions.Count) {
      $group_keys = $groups.Keys | %{ "$_" }
      $group_keys | % { $groups[$_] = script:group_items -items $groups[$_] -grouping_functions $grouping_functions -starting_index ($starting_index + 1) -default_group_name $default_group_name}
    }

    return $groups
  }

  function script:group_items {
    Param(
      [object[]]$items,
      [scriptblock[]]$grouping_functions,
      [int]$starting_index = 0,
      [string]$default_group_name = "Orphan"
    )

    $groups = @{}
    $item_index = 0
    $last_item_index = $items.Count - 1
    $is_first_item = $false
    $is_last_item = $false
    $last_tag = $default_group_name

    
    ## Add properties to each item that the grouping functions can rely on
    <#$items | % {
      if ( $item_index -eq 0 ) { $is_first_item = $true }
      if ( $item_index -eq $last_item_index ) { $is_last_item = $true }

      $state = @{
        items = $items;
        current_index = $item_index;
        last_index = $last_item_index;
        is_first_item = $is_first_item;
        is_last_item = $is_last_item;
        default_tag = $default_group_name;
        last_tag = $default_group_name;
        tag = $null;
      }

      if (-not $_.PSObject.Properties["GroupingState"]) {
        Add-Member -InputObject $_ -MemberType NoteProperty -Name GroupingState -Value $state
      } else {
        $_.GroupingState = $state
      }

      < #if (-not $_.PSObject.Properties.Name["GroupTags"]) {
        Add-Member -InputObject $_ -MemberType NoteProperty -Name GroupTags -Value @()
      }# >

      #$_.GroupingState.incoming_tags = $_.GroupingState.GroupTags

      $item_index++
    }#>

    ## Run each item through the grouping function at $starting_index
    $items | % {
      
      if ( $item_index -eq 0 ) { $is_first_item = $true } else { $is_first_item = $false }
      if ( $item_index -eq $last_item_index ) { $is_last_item = $true } else { $is_last_item = $false }

      $state = @{
        items = $items;
        current_index = $item_index;
        last_index = $last_item_index;
        is_first_item = $is_first_item;
        is_last_item = $is_last_item;
        default_tag = $default_group_name;
        last_tag = $last_tag;
        tag = $null;
      }

      if (-not $_.PSObject.Properties["GroupingState"]) {
        Add-Member -InputObject $_ -MemberType NoteProperty -Name GroupingState -Value $state
      } else {
        $_.GroupingState = $state
      }

      $item_index++

      $_

    } | % $grouping_functions[$starting_index] | % {
      
      ## Make sure the tag property on the GroupingState is a string or null
      if (($_.GroupingState.tag -ne $null) -and ($_.GroupingState.tag.GetType() -ne [string])) {
        throw "The grouping function returned the wrong type. Value must be null or a string"
      }

      ## If the tag value is null, drop the item. Otherwise...
      if ($_.GroupingState.tag -ne $null) {
        
        ## ...add the item to a hash based on the tag name
        if (-not $groups.Contains($_.GroupingState.tag)) {
          $groups[$_.GroupingState.tag] = @()
        }
        
        $groups[$_.GroupingState.tag] += $_

        ## ...set variable for the next iteration
        $last_tag = $_.GroupingState.tag
      
      }

    }

    ## Remove the GroupingState but keep the GroupTags
    $items | % {
      $_.PSObject.Properties.Remove("GroupingState")
    }

    
    <#% {

      Add-Member -InputObject $_ -MemberType NoteProperty -Name GroupingState -Value $grouping_state
      
      ## Run the item through the specified grouping function and see if a new tag is returned
      $temp_group_name = $_ | % $grouping_functions[$starting_index]

      ## If the grouping function returned a non-null value, update the group name.
      ## If the grouping function returned a null, the last value returned is in force
      if ($temp_group_name -ne $null) {
        $group_name = $temp_group_name
      }

      ## Make sure the group name is associated with an array in the 'groups' hashtable
      if ($groups.Keys -notcontains $group_name) {
        $groups[$group_name] = @()
      }

      ## Decorate the object with a new property indicating how the items has been tagged
      if ($_.PSObject.Properties.name -notcontains "GroupTag") {
        
        ## If the item has not already been decorated, add a new member
        Add-Member -InputObject $_ -MemberType NoteProperty -Name GroupTags -Value @($group_name)
      
      } else {
        
        ## If the item has already been grouped, add to the existing list of tags
        $_.GroupTags += $group_name
      
      }

      ## Remove the grouping state decorator as we don't need it any more
      $_.PSObject.Properties.Remove('GroupingState')

      ## Update the original grouping state reference for the next iterations
      $grouping_state['current_index'] += 1
      $grouping_state['last_group_name'] = $group_name

      ## Finally, add our item to the hashtable of groups
      $groups[$group_name] +=  $_
    }s
    #>

    ## If multiple grouping functions are provided, recurse
    if (($starting_index + 1) -lt $grouping_functions.Count) {
      $group_keys = $groups.Keys | %{ "$_" }
      $group_keys | % { $groups[$_] = script:group_items -items $groups[$_] -grouping_functions $grouping_functions -starting_index ($starting_index + 1) -default_group_name $default_group_name }
    }

    ## Group items based on tags into nested hash tables
    <#$group = @{}
    $items | % {
      $current_level = $group
      for ($i = 0; $i -lt $_.GroupTags.Count; $i++) {
        $tag = $_.GroupTags[$i]
        if (-not $current_level.Contains($tag)) { 
          if ($i -eq ($_.GroupTags.Count - 1)) {
            $current_level[$tag] = @()
          } else {
            $current_level[$tag] = @{}
            $current_level = $current_level[$tag]
          }
        } else {
          $current_level = $current_level[$tag]
        }
      }

      try {
        $current_level += $_
      } catch {
        throw "Item groups are nested un-evenly, unable to create hashtable"
      }
    }#>


    return $groups
  }


  function script:item_matches_filters {
    Param(
      [Parameter(ValueFromPipeline = $true)]
      [object]$item,
      
      [scriptblock[]]$filters,
      
      [ValidateSet('And','Or')]
      [string]$operator
    )

    process {
      switch ($operator) {
        'And' {
          $result = $item
          $continue_check = { $result -ne $null }
          break
        }

        'Or' {
          $result = $null
          $continue_check = { $result -eq $null }
        }
      }

      $filters | ? $continue_check | % {
        $result = Where-Object -InputObject $item -FilterScript $_
      }

      if ($result -ne $null) {
        return $true
      }

      return $false
    }

  }

  function script:get_filtered_groups {
    Param(
      [Parameter(ValueFromPipeline = $true)]
      [string]$base_path,

      [scriptblock[]]$include_filter,

      [scriptblock[]]$exclude_filter,

      [scriptblock[]]$grouping_function,

      [switch]$recurse
    )

    Begin {
    }

    Process {
      if (-not (Test-Path $base_path -PathType Container)) {
        Throw "Path must specify a container"
      }
      
      ## Filter and sort a list of items
      $filtered_sorted_items = Get-ChildItem -Path $base_path -File -Recurse:$recurse | ? {
        script:item_matches_filters -item $_ -filters $include_filter -operator And
      } | ? { 
        -not (script:item_matches_filters -item $_ -filters $exclude_filter -operator And)
      } | Sort-Object -Property CreationTime

      ## Group the items
      $groups = script:group_items -items $filtered_sorted_items -grouping_functions $grouping_function

      return $groups
    }

  }

  function script:get_newest_file {
    Param (
      [Parameter(
        Mandatory = $true,
        ValueFromPipeline = $false
      )]
      [System.IO.FileSystemInfo[]]$file_objects
    )

    $file_objects = $file_objects | Sort-Object -Property LastWriteTime

    return $file_objects[$file_objects.Count - 1]
  }

  <#
  .SYNOPSIS
	  Helper function to simplify creating dynamic parameters

  .DESCRIPTION
	  Helper function to simplify creating dynamic parameters.

	  Example use cases:
		  Include parameters only if your environment dictates it
		  Include parameters depending on the value of a user-specified parameter
		  Provide tab completion and intellisense for parameters, depending on the environment

	  Please keep in mind that all dynamic parameters you create, will not have corresponding variables created.
		  Use New-DynamicParameter with 'CreateVariables' switch in your main code block,
		  ('Process' for advanced functions) to create those variables.
		  Alternatively, manually reference $PSBoundParameters for the dynamic parameter value.

	  This function has two operating modes:

	  1. All dynamic parameters created in one pass using pipeline input to the function. This mode allows to create dynamic parameters en masse,
	  with one function call. There is no need to create and maintain custom RuntimeDefinedParameterDictionary.

	  2. Dynamic parameters are created by separate function calls and added to the RuntimeDefinedParameterDictionary you created beforehand.
	  Then you output this RuntimeDefinedParameterDictionary to the pipeline. This allows more fine-grained control of the dynamic parameters,
	  with custom conditions and so on.

  .NOTES
	  Credits to jrich523 and ramblingcookiemonster for their initial code and inspiration:
		  https://github.com/RamblingCookieMonster/PowerShell/blob/master/New-DynamicParam.ps1
		  http://ramblingcookiemonster.wordpress.com/2014/11/27/quick-hits-credentials-and-dynamic-parameters/
		  http://jrich523.wordpress.com/2013/05/30/powershell-simple-way-to-add-dynamic-parameters-to-advanced-function/

	  Credit to BM for alias and type parameters and their handling

  .PARAMETER Name
	  Name of the dynamic parameter

  .PARAMETER Type
	  Type for the dynamic parameter.  Default is string

  .PARAMETER Alias
	  If specified, one or more aliases to assign to the dynamic parameter

  .PARAMETER Mandatory
	  If specified, set the Mandatory attribute for this dynamic parameter

  .PARAMETER Position
	  If specified, set the Position attribute for this dynamic parameter

  .PARAMETER HelpMessage
	  If specified, set the HelpMessage for this dynamic parameter

  .PARAMETER DontShow
	  If specified, set the DontShow for this dynamic parameter.
	  This is the new PowerShell 4.0 attribute that hides parameter from tab-completion.
	  http://www.powershellmagazine.com/2013/07/29/pstip-hiding-parameters-from-tab-completion/

  .PARAMETER ValueFromPipeline
	  If specified, set the ValueFromPipeline attribute for this dynamic parameter

  .PARAMETER ValueFromPipelineByPropertyName
	  If specified, set the ValueFromPipelineByPropertyName attribute for this dynamic parameter

  .PARAMETER ValueFromRemainingArguments
	  If specified, set the ValueFromRemainingArguments attribute for this dynamic parameter

  .PARAMETER ParameterSetName
	  If specified, set the ParameterSet attribute for this dynamic parameter. By default parameter is added to all parameters sets.

  .PARAMETER AllowNull
	  If specified, set the AllowNull attribute of this dynamic parameter

  .PARAMETER AllowEmptyString
	  If specified, set the AllowEmptyString attribute of this dynamic parameter

  .PARAMETER AllowEmptyCollection
	  If specified, set the AllowEmptyCollection attribute of this dynamic parameter

  .PARAMETER ValidateNotNull
	  If specified, set the ValidateNotNull attribute of this dynamic parameter

  .PARAMETER ValidateNotNullOrEmpty
	  If specified, set the ValidateNotNullOrEmpty attribute of this dynamic parameter

  .PARAMETER ValidateRange
	  If specified, set the ValidateRange attribute of this dynamic parameter

  .PARAMETER ValidateLength
	  If specified, set the ValidateLength attribute of this dynamic parameter

  .PARAMETER ValidatePattern
	  If specified, set the ValidatePattern attribute of this dynamic parameter

  .PARAMETER ValidateScript
	  If specified, set the ValidateScript attribute of this dynamic parameter

  .PARAMETER ValidateSet
	  If specified, set the ValidateSet attribute of this dynamic parameter

  .PARAMETER Dictionary
	  If specified, add resulting RuntimeDefinedParameter to an existing RuntimeDefinedParameterDictionary.
	  Appropriate for custom dynamic parameters creation.

	  If not specified, create and return a RuntimeDefinedParameterDictionary
	  Aappropriate for a simple dynamic parameter creation.

  .EXAMPLE
	  Examples removed for brevity.

  #>
  Function New-DynamicParameter {
	  [CmdletBinding(PositionalBinding = $false, DefaultParameterSetName = 'DynamicParameter')]
	  Param
	  (
		  [Parameter(Mandatory = $true, ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true, ParameterSetName = 'DynamicParameter')]
		  [ValidateNotNullOrEmpty()]
		  [string]$Name,

		  [Parameter(ValueFromPipelineByPropertyName = $true, ParameterSetName = 'DynamicParameter')]
		  [System.Type]$Type = [int],

		  [Parameter(ValueFromPipelineByPropertyName = $true, ParameterSetName = 'DynamicParameter')]
		  [string[]]$Alias,

		  [Parameter(ValueFromPipelineByPropertyName = $true, ParameterSetName = 'DynamicParameter')]
		  [switch]$Mandatory,

		  [Parameter(ValueFromPipelineByPropertyName = $true, ParameterSetName = 'DynamicParameter')]
		  [int]$Position,

		  [Parameter(ValueFromPipelineByPropertyName = $true, ParameterSetName = 'DynamicParameter')]
		  [string]$HelpMessage,

		  [Parameter(ValueFromPipelineByPropertyName = $true, ParameterSetName = 'DynamicParameter')]
		  [switch]$DontShow,

		  [Parameter(ValueFromPipelineByPropertyName = $true, ParameterSetName = 'DynamicParameter')]
		  [switch]$ValueFromPipeline,

		  [Parameter(ValueFromPipelineByPropertyName = $true, ParameterSetName = 'DynamicParameter')]
		  [switch]$ValueFromPipelineByPropertyName,

		  [Parameter(ValueFromPipelineByPropertyName = $true, ParameterSetName = 'DynamicParameter')]
		  [switch]$ValueFromRemainingArguments,

		  [Parameter(ValueFromPipelineByPropertyName = $true, ParameterSetName = 'DynamicParameter')]
		  [string]$ParameterSetName = '__AllParameterSets',

		  [Parameter(ValueFromPipelineByPropertyName = $true, ParameterSetName = 'DynamicParameter')]
		  [switch]$AllowNull,

		  [Parameter(ValueFromPipelineByPropertyName = $true, ParameterSetName = 'DynamicParameter')]
		  [switch]$AllowEmptyString,

		  [Parameter(ValueFromPipelineByPropertyName = $true, ParameterSetName = 'DynamicParameter')]
		  [switch]$AllowEmptyCollection,

		  [Parameter(ValueFromPipelineByPropertyName = $true, ParameterSetName = 'DynamicParameter')]
		  [switch]$ValidateNotNull,

		  [Parameter(ValueFromPipelineByPropertyName = $true, ParameterSetName = 'DynamicParameter')]
		  [switch]$ValidateNotNullOrEmpty,

		  [Parameter(ValueFromPipelineByPropertyName = $true, ParameterSetName = 'DynamicParameter')]
		  [ValidateCount(2,2)]
		  [int[]]$ValidateCount,

		  [Parameter(ValueFromPipelineByPropertyName = $true, ParameterSetName = 'DynamicParameter')]
		  [ValidateCount(2,2)]
		  [int[]]$ValidateRange,

		  [Parameter(ValueFromPipelineByPropertyName = $true, ParameterSetName = 'DynamicParameter')]
		  [ValidateCount(2,2)]
		  [int[]]$ValidateLength,

		  [Parameter(ValueFromPipelineByPropertyName = $true, ParameterSetName = 'DynamicParameter')]
		  [ValidateNotNullOrEmpty()]
		  [string]$ValidatePattern,

		  [Parameter(ValueFromPipelineByPropertyName = $true, ParameterSetName = 'DynamicParameter')]
		  [ValidateNotNullOrEmpty()]
		  [scriptblock]$ValidateScript,

		  [Parameter(ValueFromPipelineByPropertyName = $true, ParameterSetName = 'DynamicParameter')]
		  [ValidateNotNullOrEmpty()]
		  [string[]]$ValidateSet,

		  [Parameter(ValueFromPipelineByPropertyName = $true, ParameterSetName = 'DynamicParameter')]
		  [object]$Default = $null,

		  [Parameter(ValueFromPipelineByPropertyName = $true, ParameterSetName = 'DynamicParameter')]
		  [ValidateNotNullOrEmpty()]
		  [ValidateScript({
			  if(!($_ -is [System.Management.Automation.RuntimeDefinedParameterDictionary]))
			  {
				  Throw 'Dictionary must be a System.Management.Automation.RuntimeDefinedParameterDictionary object'
			  }
			  $true
		  })]
		  $Dictionary = $false,

		  [Parameter(Mandatory = $true, ValueFromPipelineByPropertyName = $true, ParameterSetName = 'CreateVariables')]
		  [switch]$CreateVariables,

		  [Parameter(Mandatory = $true, ValueFromPipelineByPropertyName = $true, ParameterSetName = 'CreateVariables')]
		  [ValidateNotNullOrEmpty()]
		  [ValidateScript({
			  # System.Management.Automation.PSBoundParametersDictionary is an internal sealed class,
			  # so one can't use PowerShell's '-is' operator to validate type.
			  if($_.GetType().Name -ne 'PSBoundParametersDictionary')
			  {
				  Throw 'BoundParameters must be a System.Management.Automation.PSBoundParametersDictionary object'
			  }
			  $true
		  })]
		  $BoundParameters
	  )

	  Begin
	  {
		  Write-Verbose 'Creating new dynamic parameters dictionary'
		  $InternalDictionary = New-Object -TypeName System.Management.Automation.RuntimeDefinedParameterDictionary

		  Write-Verbose 'Getting common parameters'
		  function _temp { [CmdletBinding()] Param() }
		  $CommonParameters = (Get-Command _temp).Parameters.Keys
	  }

	  Process
	  {
		  if($CreateVariables)
		  {
			  Write-Verbose 'Creating variables from bound parameters'
			  Write-Debug 'Picking out bound parameters that are not in common parameters set'
			  $BoundKeys = $BoundParameters.Keys | Where-Object { $CommonParameters -notcontains $_ }

			  foreach($Parameter in $BoundKeys)
			  {
				  Write-Debug "Setting existing variable for dynamic parameter '$Parameter' with value '$($BoundParameters.$Parameter)'"
				  Set-Variable -Name $Parameter -Value $BoundParameters.$Parameter -Scope 1 -Force
			  }
		  }
		  else
		  {
			  Write-Verbose 'Looking for cached bound parameters'
			  Write-Debug 'More info: https://beatcracker.wordpress.com/2014/12/18/psboundparameters-pipeline-and-the-valuefrompipelinebypropertyname-parameter-attribute'
			  $StaleKeys = @()
			  $StaleKeys = $PSBoundParameters.GetEnumerator() |
						  ForEach-Object {
							  if($_.Value.PSobject.Methods.Name -match '^Equals$')
							  {
								  # If object has Equals, compare bound key and variable using it
								  if(!$_.Value.Equals((Get-Variable -Name $_.Key -ValueOnly -Scope 0)))
								  {
									  $_.Key
								  }
							  }
							  else
							  {
								  # If object doesn't has Equals (e.g. $null), fallback to the PowerShell's -ne operator
								  if($_.Value -ne (Get-Variable -Name $_.Key -ValueOnly -Scope 0))
								  {
									  $_.Key
								  }
							  }
						  }
			  if($StaleKeys)
			  {
				  "Found $($StaleKeys.Count) cached bound parameters:",  $StaleKeys | Out-String | Write-Debug
				  Write-Verbose 'Removing cached bound parameters'
				  $StaleKeys | ForEach-Object {[void]$PSBoundParameters.Remove($_)}
			  }

			  # Since we rely solely on $PSBoundParameters, we don't have access to default values for unbound parameters
			  Write-Verbose 'Looking for unbound parameters with default values'

			  Write-Debug 'Getting unbound parameters list'
			  $UnboundParameters = (Get-Command -Name ($PSCmdlet.MyInvocation.InvocationName)).Parameters.GetEnumerator()  |
										  # Find parameters that are belong to the current parameter set
										  Where-Object { $_.Value.ParameterSets.Keys -contains $PsCmdlet.ParameterSetName } |
											  Select-Object -ExpandProperty Key |
												  # Find unbound parameters in the current parameter set
												  Where-Object { $PSBoundParameters.Keys -notcontains $_ }

			  # Even if parameter is not bound, corresponding variable is created with parameter's default value (if specified)
			  Write-Debug 'Trying to get variables with default parameter value and create a new bound parameter''s'
			  $tmp = $null
			  foreach($Parameter in $UnboundParameters)
			  {
				  $DefaultValue = Get-Variable -Name $Parameter -ValueOnly -Scope 0
				  if(!$PSBoundParameters.TryGetValue($Parameter, [ref]$tmp) -and $DefaultValue)
				  {
					  $PSBoundParameters.$Parameter = $DefaultValue
					  Write-Debug "Added new parameter '$Parameter' with value '$DefaultValue'"
				  }
			  }

			  if($Dictionary)
			  {
				  Write-Verbose 'Using external dynamic parameter dictionary'
				  $DPDictionary = $Dictionary
			  }
			  else
			  {
				  Write-Verbose 'Using internal dynamic parameter dictionary'
				  $DPDictionary = $InternalDictionary
			  }

			  Write-Verbose "Creating new dynamic parameter: $Name"

			  # Shortcut for getting local variables
			  $GetVar = {Get-Variable -Name $_ -ValueOnly -Scope 0}

			  # Strings to match attributes and validation arguments
			  $AttributeRegex = '^(Mandatory|Position|ParameterSetName|DontShow|ValueFromPipeline|ValueFromPipelineByPropertyName|ValueFromRemainingArguments)$'
			  $ValidationRegex = '^(AllowNull|AllowEmptyString|AllowEmptyCollection|ValidateCount|ValidateLength|ValidatePattern|ValidateRange|ValidateScript|ValidateSet|ValidateNotNull|ValidateNotNullOrEmpty)$'
			  $AliasRegex = '^Alias$'

			  Write-Debug 'Creating new parameter''s attirubutes object'
			  $ParameterAttribute = New-Object -TypeName System.Management.Automation.ParameterAttribute

			  Write-Debug 'Looping through the bound parameters, setting attirubutes...'
			  switch -regex ($PSBoundParameters.Keys)
			  {
				  $AttributeRegex
				  {
					  Try
					  {
						  $ParameterAttribute.$_ = . $GetVar
						  Write-Debug "Added new parameter attribute: $_"
					  }
					  Catch
					  {
						  $_
					  }
					  continue
				  }
			  }

			  if($DPDictionary.Keys -contains $Name)
			  {
				  Write-Verbose "Dynamic parameter '$Name' already exist, adding another parameter set to it"
				  $DPDictionary.$Name.Attributes.Add($ParameterAttribute)
			  }
			  else
			  {
				  Write-Verbose "Dynamic parameter '$Name' doesn't exist, creating"

				  Write-Debug 'Creating new attribute collection object'
				  $AttributeCollection = New-Object -TypeName Collections.ObjectModel.Collection[System.Attribute]

				  Write-Debug 'Looping through bound parameters, adding attributes'
				  switch -regex ($PSBoundParameters.Keys)
				  {
					  $ValidationRegex
					  {
						  Try
						  {
							  $ParameterOptions = New-Object -TypeName "System.Management.Automation.$_`Attribute" -ArgumentList (. $GetVar) -ErrorAction SilentlyContinue
							  $AttributeCollection.Add($ParameterOptions)
							  Write-Debug "Added attribute: $_"
						  }
						  Catch
						  {
							  $_
						  }
						  continue
					  }

					  $AliasRegex
					  {
						  Try
						  {
							  $ParameterAlias = New-Object -TypeName System.Management.Automation.AliasAttribute -ArgumentList (. $GetVar) -ErrorAction SilentlyContinue
							  $AttributeCollection.Add((. $GetVar))
							  Write-Debug "Added alias: $_"
							  continue
						  }
						  Catch
						  {
							  $_
						  }
					  }
				  }

				  Write-Debug 'Adding attributes to the attribute collection'
				  $AttributeCollection.Add($ParameterAttribute)

				  Write-Debug 'Finishing creation of the new dynamic parameter'
				  $Parameter = New-Object -TypeName System.Management.Automation.RuntimeDefinedParameter -ArgumentList @($Name, $Type, $AttributeCollection)
          
          Write-Debug 'Adding default value'
          if ($Default -ne $null)
          {
            if ($Default -is $Type)
            {
              $Parameter.Value = $Default
            }
            else
            {
              Throw "The default value supplied for the $Name parameter is of type $($Default.GetType()), but $Name has been specified as type $Type"
            }
          }

				  Write-Debug 'Adding dynamic parameter to the dynamic parameter dictionary'
				  $DPDictionary.Add($Name, $Parameter)
			  }
		  }
	  }

	  End
	  {
		  if(!$CreateVariables -and !$Dictionary)
		  {
			  Write-Verbose 'Writing dynamic parameter dictionary to the pipeline'
			  $DPDictionary
		  }
	  }
  }

  function New-ArchiveTask {
  
    [CmdletBinding()]
  
    Param(
      [Parameter(
        ValueFromPipeline=$false,
        ValueFromPipelineByPropertyName=$true
      )]
      [switch]$RetainProcessedItems = $false
    )

    DynamicParam {

      ### =====================================================================================
      ### ADD DYNAMIC PARAMETERS
      ### =====================================================================================
      $function_parameters = $common_task_parameters + @(
        @{
          Name = "ArchiveNamingMethod";
          Type = ([string]);
          Mandatory = $true;
          Position = 7;
          ValueFromPipeline = $false;
          ValueFromPipelineByPropertyName = $true;
          HelpMessage = "The base path containing items to be processed";
          ValidateSet = $naming_functions.Keys;
        }
      )

      $function_parameters | % { New-Object psobject -Property $_ } | New-DynamicParameter

    }

    Begin {
      # Create friendly variable names for dynamic parameters
      $function_parameters | % {
        Set-Variable -Name $_.Name -Value $PsBoundParameters[$_.Name]
      }
    }

    Process {

      # Group items starting in the base path first by directory, then by grouping function
      $item_groups = script:get_filtered_groups `
        -base_path $Path `
        -include_filter { $_.FullName -match $Include } `
        -exclude_filter { $_.FullName -match $Exclude } `
        -grouping_function @({$_.GroupingState.tag = $_.DirectoryName; $_}, $grouping_functions[$ItemGroupingMethod]) `
        -recurse:$Recurse

      # Archive groups within directories
      $item_groups.Keys | % {
      
        # Retain the base path of the item group
        $group_base_path = $_

        # Pass the groups items down the pipe
        $item_groups[$group_base_path].Keys | ? { 
        
          # If the newest file in the group is within the "UnactionableTimespan", skip the group
          (script:get_newest_file -file_objects $item_groups[$group_base_path][$_]).LastWriteTime.AddMilliseconds($UnactionableTimespan.TotalMilliseconds) -le (Get-Date)

        } | % {

          # Split the group into one or more archives using the specified naming function
          # 2do: If I don't allow custom naming function, I don't need the "Invalid" default group name
          $archive_name_groups = script:group_items -items $item_groups[$group_base_path][$_] -grouping_functions $naming_functions[$ArchiveNamingMethod] -default_group_name "Invalid"

          $archives_created = @()
          foreach ($archive_name in $archive_name_groups.Keys) {

            $full_archive_name = $group_base_path + "\" + $archive_name + ".7z"
            $item_name_strings = $archive_name_groups[$archive_name] | % { $_.FullName }

            ## Append or create the archive
            if ($WhatIf) {
              Write-Host "`nWhat if: Performing the operation Add-7zArchive on target `"$full_archive_name`" with the following items:"
              $item_name_strings | %{ Write-Host "`tAdding: $_" }
            } else {
              Add-7zArchive -Path $full_archive_name -Include $item_name_strings
            }

            ## Test the archive to see if it was created successfully
            if ($WhatIf) {
              Write-Host "What if: Performing the operation Test-7zArchive on target `"$full_archive_name`" with the option, 'FailIfEmpty'"
              $archive_ok = $true
            } else {
              try {
                $archive_ok = Test-7zArchive -Path $full_archive_name -FailIfEmpty
              } catch {
                $archive_ok = $false
              }
            }

            ## If the archive isn't okay, stop processing
            if (-not $archive_ok) {
              Write-Error "The archive, $full_archive_name, failed consistency checks."
              break
            }

            ## Otherwise, rock on
            $archives_created += $full_archive_name

          }

          # If the archive group wasn't scompleted...
          if ($archives_created.Count -lt $archive_name_groups.Keys.Count) {

            # ...delete the archive and log the error
            Write-Error "One or more archives failed consistency checks. Archives in the current group will be deleted and the group files left in place."
            $archives_created | Remove-Item -Force -WhatIf:$WhatIf

          } elseif (-not $RetainProcessedItems) {

            # And the delete_original option is set,  the Delete the source files
            $item_name_strings | Remove-Item -Force -WhatIf:$WhatIf

          }

          return $archives_created

        }
      
      }

    }

    End {}
  }

  function New-CycleTask {
  
    [CmdletBinding()]
  
    Param(
      [Parameter(
        Position=7,
        ValueFromPipeline=$false,
        ValueFromPipelineByPropertyName=$true
      )]
      [int]$MaximumFileVersions = -1
    )

    DynamicParam {

      ### =====================================================================================
      ### ADD DYNAMIC PARAMETERS
      ### =====================================================================================
      $function_parameters = $common_task_parameters

      $function_parameters | % { New-Object psobject -Property $_ } | New-DynamicParameter

    }

    Begin {
      # Create friendly variables for dynamic parameters
      $function_parameters | % {
        Set-Variable -Name $_.Name -Value $PsBoundParameters[$_.Name]
      }
    }
    Process {}
    End { Write-Host $ItemGroupingMethod; Write-Host $ArchiveNamingMethod}
  }

  Export-ModuleMember -Function @(
    "New-ArchiveTask"
  )
} | Out-Null

### =====================================================================================
### USER CONFIGURATION SECTION
###
### Include one or more hashtable as follows:
### @{
###   path= <path to FOLDER containing target files as string>;
###   recurse= <$true|$false>; #true := process files in 'path' and all subfolders under 'path'
###   whitelist_filter= <[RegEx] Object>; #Example (include everything): [regex]::new('.*') 
###   blacklist_filter= <[RegEx] Object>; #Example (exclude nothing) [regex]::new('^$')
###   max_age_span= <[System.TimeSpan] object>; #Example (7 day span): [System.TimeSpan]::new(7,0,0,0)
###   what_if= <$true|$false>; #Run in "WhatIf" mode for testing (see output in log file)
### }
### =====================================================================================
$archive_task_results = New-ArchiveTask -Path "D:\Temp\CnC Tests" `
                -ItemGroupingMethod BySQLFulls `
                -ArchiveNamingMethod "Parent+ModifiedDateByDay" `
                -Include '\.(bak|trn|dif)$' `
                -Exclude '\.(zip|7z)$' `
                -UnactionableTimeSpan (New-Object System.TimeSpan(1,0,0,0)) `
                -Recurse `
                -WhatIF:$true `
                -RetainProcessedItems

New-CycleTask   -Path "D:\Temp\CnC Tests" `
                -ItemGroupingMethod None `
                -MaximumFileVersions 1 `
                -Include '\.(zip|7z)$' `
                -UnactionableTimeSpan (New-Object System.TimeSpan(30,0,0,0)) `
                -Recurse `
                -WhatIF

break

$workLoad = @{
	path = "D:\Temp\CnC Tests";
	recurse = $true;
	whitelist_filter = [regex] '\.(bak|trn|dif)$';
	blacklist_filter = [regex] '\.(zip|7z)$';
  what_if = $false;
  group_by = "SQLFulls" # None | Hour | Day | Month | Year | SQLFulls"
  #action = "Compress" # Compress | Cycle
  compress = @{
    compress_after_timespan = New-Object System.TimeSpan(1,0,0,0);
    #archive_path = "D:\Temp\Syslog\a10_a10networks"; # Currently, this script just archives groups in place
    name_function = "Parent+Group";
    #test_archive = $true;  # Always test the archive
    delete_original = $false;
  };
  <#cycle = @{
    max_historical_versions = 0;
    append_version_numbers = $false;
    max_age_timespan = New-Object System.TimeSpan(7,0,0,0);
  };#>
  #compress_after_timespan = New-Object System.TimeSpan(7,0,0,0);
  #cycle_after_timespan = New-Object System.TimeSpan(7,0,0,0);
}

### =====================================================================================
### SCRIPT CONFIGURATION SECTION
### =====================================================================================
$logging = @{
  target_log_file = "$PSScriptRoot\$(Split-Path $PSCommandPath -leaf).log";
  target_transcript_file = "$PSScriptRoot\$(Split-Path $PSCommandPath -leaf).transcript";
  target_event_log = "Automation";
  event_source = "Powershell Script";
  invocation_data = @{
    "Script Name" = &{ $MyInvocation.ScriptName };
    "Command Line" = $MyInvocation.Line;
    "History ID" = $MyInvocation.HistoryId;
    "Process ID" = $PID;
  };
}

$required_modules = @(
  "C:\Users\matthew.johnson\Source\Repos\7-Zip-PSM\7-Zip PSM\7-Zip.psm1"
)

$module_search_paths = @(
  $PSScriptRoot,
  (Get-Item ($PSScriptRoot + "\..\..\7-Zip-PSM\7-Zip PSM")).FullName
)

$grouping_scripts = @{
  None = { $_.Name };
  Day = { $_.CreationTime.DayofYear };
  SQLFulls = { if ($_.Extension -like ".bak") { $_.Name } else { $null } };
}

$naming_scripts = @{
  "FirstItem" = { begin { $first = $true } process{ if ($first) { $first = $false; $_.Name } else { $null } } }
  "LastItem" = { $_.Name }
  #"Parent+DateToMinute" = { (Split-Path $_.FullName -Parent).Split("\")[-1] + "_" + (Get-Date -Format "yyyy.MM.dd HHmm00"); break };
  #"Parent+DateToHour" = { (Split-Path $_.FullName -Parent).Split("\")[-1] + "_" + (Get-Date -Format "yyyy.MM.dd HH0000"); break };
  #"Parent+DateToDay" = { (Split-Path $_.FullName -Parent).Split("\")[-1] + "_" + (Get-Date -Format "yyyy.MM.dd"); break };
  "Parent+Group" = { ((Split-Path $_.FullName -Parent).Split("\")[-1] + "_" + $_.GroupTag) -replace "[<>:`"/\|?*]", "_" };
}


### =====================================================================================
### IMPORT REQUIRED MODULES
### =====================================================================================
$Env:PSModulePath = ($module_search_paths -join ";") + ";" + $Env:PSModulePath
$required_modules | % {
  try {
    Import-Module "$_" -ErrorAction Stop
  } catch {
    throw [System.IO.FileNotFoundException] "Unable to locate the required module, $_"
  }
}


### Compile basic script information as a string for logging
$invocation_information  = "INVOCATION INFORMATION:`n-------------------------------------"
foreach ($key in $logging.invocation_data.keys) {
  $invocation_information += "`n$key`: $($logging.invocation_data.$key)"
}

### Write logs before processing workload to mark the beginning of the run
Write-EventLog -LogName $logging.target_event_log -Source $logging.event_source -EventId 0 -EntryType 'Information' `
  -Message "Begin processing $($workLoad.Count) base paths`n`n$invocation_information"

### If any of the logging commands failed, stop the script and attempt to inform operator
if (-not $?) {
  $message = "Unable to write to the '$target_event_log' event log. Make sure the event log exists and that the " + `
    "security context under which this script runs has 'write' permissions on it."
  
  $message | Out-File $logging.target_log_file -Force
  $message | Write-Host -ForegroundColor Yellow
  break;
}

# Start transcript to capture -WhatIf output if $config.what_if == $true
if ($config.what_if) {
  Start-Transcript -Path $logging.target_transcript_file -Append
  "Base path $($config.path)"
}

### =====================================================================================
### START THE ACTUAL WORK
### =====================================================================================
foreach ($config in $workLoad) {
  ## Make sure our config is correct
  # Check 'group_by'
  if (-not ($config.Contains('group_by') -and ($config.group_by.Split(":")[0] -in $grouping_scripts.Keys))) {
    
  }
  
  # Get the list of directories we'll be working in
  $paths = @(Get-Item $config.path)

  # If we weren't able to retreive the path, continue to the next workload
  if (-not $?) {
    continue
  }

  # If the recurse option has been specified, append a full list of subfolders to the base path
  if ($config.recurse) {
    $paths += Get-ChildItem -Path $config.path -Recurse -Directory
  }
  
  # Work through the paths one at a time
  
  $paths | % {
    $group_tag = "none"

    $grouped_items = $_ | Get-ChildItem -File | ?{

      $config.whitelist_filter.Match($_.FullName).Success # Pass only the whitelisted files down the pipe

    } | ?{

      -not $config.blacklist_filter.Match($_.FullName).Success # Exclude blacklisted files

    } | Sort-Object -Property CreationTime | %{ 

      $new_group_tag = $_ | % $grouping_scripts[$config.group_by]

      if ($new_group_tag -ne $null) {
        $group_tag = $new_group_tag
      } 
      
      $_

    } | %{ 
      Add-Member -InputObject $_ -MemberType NoteProperty -Name GroupTag -Value $group_tag

      $_ 
    } | Group-Object -Property GroupTag

    ## If there are not groups (blank directory), continue to the next path
    if ($grouped_items.Count -eq 0) {
      return
    }

    ## If the workload defines a compress action...
    if ($config.Keys -contains 'compress') {

      ## Process each group for compression
      ## Note, the groupd_items object is not a hashtable
      $grouped_items | % {
        
        $item_group = $_.Group

        ## Is the newest item in the group old enough for compression to commence?
        ## Items should still be sorted chronologically, so check the last item
        $t_items = $item_group.Count
        $t_lastWriteTime = $item_group[$t_items - 1].LastWriteTime
        $t_time_test = $t_lastWriteTime.AddMilliseconds($config.compress.compress_after_timespan.TotalMilliseconds)
        if ($item_group[$item_group.Count - 1].LastWriteTime.AddMilliseconds($config.compress.compress_after_timespan.TotalMilliseconds) -ge (Get-Date)) {

          ## The group is not old enough for compression - so continue to the next group
          return
        }

        ## The group is old enough, so lets find out what we should name the compressed archive
        $archive_name = ""
        $item_group | % {
          
          $temp_name = $_ | % $naming_scripts[$config.compress.name_function]

          if ($temp_name -ne $null) {
            $archive_name = $temp_name
          }

        }

        ## If $archive_name is blank, throw an error
        if ([String]::IsNullOrWhiteSpace($archive_name)) {
          ## 2do: come up with a better exception (and exception text)...
          Throw [System.IO.FileLoadException] "No archive name could be derived"
        }

        ## Compress the group of files using the derived archive name
        ## If the archive already exists, it will be appended
        $full_archive_name = $item_group[1].DirectoryName + "\" + $archive_name + ".7z"
        $item_name_strings = $item_group |  % { $_.FullName }

        if ($config.what_if) {
          Write-Host "What if: Creating archive $full_archive_name"
          $item_name_strings | %{ Write-Host "`tAdding: $_" }
          Write-Host "`nWhat if: Add-7zArchive -Path $full_archive_name -Include `$item_name_strings -Type Zip"
        } else {
          Add-7zArchive -Path $full_archive_name -Include $item_name_strings
        }

        ## Test the archive to see if it was created successfully
        if ($config.what_if) {
          Write-Host "What if: Test-7zArchive -Path $full_archive_name -FailIfEmpty"
          $archive_ok = $true
        } else {
          try {
            $archive_ok = Test-7zArchive -Path $full_archive_name -FailIfEmpty
          } catch {
            $archive_ok = $false
          }
        }

        # If the archive isn't healthy...
        if (-not $archive_ok) {

          # ...delete the archive and log the error
          Write-Error "$full_archive_name failed consistency checks. The archive was deleted and the file group remains in place."
          Remove-Item -Path $full_archive_name -Force -WhatIf:$config.what_if

        } elseif ($config.compress.delete_original) {

          # And the delete_original option is set,  the Delete the source files
          $item_name_strings | Remove-Item -Force -WhatIf:$config.what_if

        }
      } | Out-Null
    }
  } | Out-Null


  
  <#?{
    $_.LastWriteTime -lt [System.DateTime]::Now.AddTicks([Math]::Abs($config.max_age_span.Ticks)*-1) # Find files older than the specified span
  } | Remove-Item -Force -WhatIF:$config.what_if # delete the whitelisted old files that were not otherwise excluded#>
  
} 

if ($config.what_if) {
  Stop-Transcript | Out-Null
}

### Log the results of the script
if ($Error.Count -gt 0) {
  $Error | Out-File $logging.target_log_file -Force
  Write-EventLog -LogName $logging.target_event_log -Source $logging.event_source -EventId 0 -EntryType 'Error' `
    -Message ("Processed $($workLoad.Count) base paths and encountered " `
    + "$($Error.Count) errors. See the `"$($logging.target_log_file)`" file for error details." `
    + "`n`n$invocation_information")
} else {
  Write-EventLog -LogName $logging.target_event_log -Source $logging.event_source -EventId 0 -EntryType 'Information' `
    -Message ("Processed $($workLoad.Count) base paths successfully." `
    + "`n`n$invocation_information")
}