resource "azapi_resource" "application_insights" {
  type      = "Microsoft.Insights/components@2020-02-02"
  name      = var.name
  parent_id = var.resource_group_id
  location  = var.location
  tags      = var.tags

  body = {
    kind = "web"
    properties = {
      Application_Type    = "web"
      WorkspaceResourceId = var.log_analytics_workspace_id
    }
  }

  response_export_values = ["properties.ConnectionString"]
}
