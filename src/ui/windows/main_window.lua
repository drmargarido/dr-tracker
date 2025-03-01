-- Controllers
local add_task = require "src.controller.add_task"
local stop_task = require "src.controller.stop_task"
local delete_task = require "src.controller.delete_task"
local list_today_tasks = require "src.controller.list_today_tasks"
local autocomplete_task = require "src.controller.autocomplete_task"
local autocomplete_project = require "src.controller.autocomplete_project"
local get_task_in_progress = require "src.controller.get_task_in_progress"
local get_task_by_description = require "src.controller.get_task_by_description"

-- Exporters
local xml_export = require "src.exporter.xml"
local csv_export = require "src.exporter.csv"

-- Settings
local storage = require "src.storage"

-- Utils
local date = require "date.date"
local utils = require "src.utils"
local report_error = require "src.ui.utils".report_error

-- UI components
local ui = require "tek.ui"
local TaskRow = require "src.ui.components.task_row"
local InputWithPlaceholder = require "src.ui.components.input_with_placeholder"
local InputWithAutocomplete = require "src.ui.components.input_with_autocomplete"

-- Plugins
local events = require "src.plugin_manager.events"

-- Windows
local stats_window = require "src.ui.windows.stats_window"
local notification_window = require "src.ui.windows.notification_window"
local this_window

local width = 800
local height = 600

local _refresh

_refresh = function()
    local r1, r2, r3, r4 = this_window:getRect()

    if r1 and r2 and r3 and r4 then
        width = r3 - r1 + 1
        height = r4 - r2 + 1
    end

    -- Clear row selection
    TaskRow.clear_selection()

    -- Get UI elements
    local current_activity_element = this_window:getById("current_activity_text")
    local stop_tracking_element = this_window:getById("stop_tracking_button")
    local task_list_group_element = this_window:getById("task_list_group")
    local total_time_element = this_window:getById("total_time_text")

    -- Prepare the updated data
    local today_tasks = list_today_tasks()
    local current_task = get_task_in_progress()

    -- Add current task to the today tasks list if its not there already
    local has_task_in_progress = false
    if current_task ~= nil then
        has_task_in_progress = true

        local task_in_list = false
        for _, task in ipairs(today_tasks) do
            if task.id == current_task.id then
                task_in_list = true
            end
        end

        if not task_in_list then
            table.insert(today_tasks, current_task)
        end
    end

    local current_activity_text = "No Activity"
    if has_task_in_progress then
        current_activity_text = utils.trim_text(
            current_task.description.." - "..current_task.project, width / 14
        )
    end

    -- Calculate total time
    local total_time = nil
    for _, task in ipairs(today_tasks) do
        local start_time = date(task.start_time)

        local end_time = date(task.end_time)
        local duration = date.diff(end_time, start_time)

        if not total_time then
            total_time = duration
        else
            total_time = total_time + duration
        end
    end

    local total_time_text = "No records today"
    if total_time then
        total_time_text = string.format(
            "Total Time: %02dh %02dmin",
            total_time:spanhours(),
            total_time:getminutes()
        )
    end

    -- Set the updated data in the UI elements
    local tasks_rows = {}
    for _, task in ipairs(today_tasks) do
        table.insert(tasks_rows, TaskRow.new(task, _refresh, width))
    end

    current_activity_element:setValue("Text", current_activity_text)
    stop_tracking_element.Disabled = not has_task_in_progress
    stop_tracking_element:onDisable() -- Trigger UI update

    total_time_element:setValue("Text", total_time_text)

    -- Configure export xml callback
    this_window:getById("export_xml_btn"):setValue("onPress", function(_self)
        local app = this_window.Application
        app:addCoroutine(function()
            local status, path, select = _self.Application:requestFile{
                Title = "Select the export path",
                SelectText = "save",
                Location = date():fmt("%F")..".xml",
                Path = storage.data.xml_save_path
            }

            if status == "selected" then
                storage.data.xml_save_path = path
                storage:save()

                local fname = path .. "/" .. select[1]
                report_error(xml_export.write_xml_to_file(today_tasks, fname))
            end
        end)
    end)

    -- Configure export csv callback
    this_window:getById("export_csv_btn"):setValue("onPress", function(_self)
        local app = this_window.Application
        app:addCoroutine(function()
            local status, path, select = _self.Application:requestFile{
                Title = "Select the export path",
                SelectText = "save",
                Location = date():fmt("%F")..".csv",
                Path = storage.data.csv_save_path
            }

            if status == "selected" then
                storage.data.csv_save_path = path
                storage:save()

                local fname = path .. "/" .. select[1]
                report_error(csv_export.write_csv_to_file(today_tasks, fname))
            end
        end)
    end)

    -- Clear old tasks rows
    while #task_list_group_element.Children > 0 do
        task_list_group_element:remMember(task_list_group_element.Children[1])
    end

    -- Add new tasks rows
    for _, row in ipairs(tasks_rows) do
        task_list_group_element:addMember(row)
    end
end

return {
    -- Update the UI with data according to the current db state
    refresh = _refresh,

    init = function(plugins)

        -- Register plugins in the menubar
        local plugin_entries = {}
        for _, plugin in ipairs(plugins) do
            if plugin.conf and plugin.conf.in_menu then
                table.insert(
                    plugin_entries,
                    ui.MenuItem:new{
                        Width = "fill",
                        Style = "text-align: center;",
                        Text = plugin.conf.description or "Unnamed",
                        onClick = plugin.event_listeners[events.PLUGIN_SELECT] or function()end
                    }
                )
            end
        end

        local task_autocomplete = InputWithAutocomplete:new{
            Callback = autocomplete_task,
            Id = "task-description",
            Width = "free",
            MinWidth = 240,
            Placeholder = "Description",
            onAutocomplete = function(self, text)
                self:setValue("Text", text)

                local task = get_task_by_description(text)
                local project_input = this_window:getById("task-project")
                project_input:setValue("Text", task.project)
                project_input.Child.Child:setValue("Class", "")
            end,
            onEnter = function(self)
                local start_button = self:getById("start_tracking_button")
                start_button:setValue("Pressed", true)
                start_button:setValue("Pressed", false)
            end
        };

        local project_autocomplete = InputWithAutocomplete:new{
            Callback = autocomplete_project,
            Id = "task-project",
            Width = "free",
            Placeholder = "Project",
            onEnter = function(self)
                local start_button = self:getById("start_tracking_button")
                start_button:setValue("Pressed", true)
                start_button:setValue("Pressed", false)
            end
        }

        this_window = ui.Window:new {
            Title = "D-Tracker",
            Orientation = "vertical",
            Top = 100,
            Left = 100,
            Width = width,
            Height = height,
            MaxWidth = "none",
            MaxHeight = "none";
            MinWidth = 250,
            MinHeight = 250;
            HideOnEscape = true,
            SizeButton = true,
            Id = "main_ui_window",
            RootWindow = true,
            Children = {
                ui.Group:new{
                    Class = "menubar",
                    Children = {
                        ui.MenuItem:new {
                            Width = 70,
							Text = "File",
                            Style = "text-align: center;",
							Children ={
								ui.MenuItem:new{
                                    Width = 70,
                                    Style = "text-align: center;",
                                    Text = "About",
									onClick = function(self)
                                        local _, _, x, y = self.Window.Drawable:getAttrs()

                                        -- Archor to the main window position
                                        local about_window = self:getById("about-window")
                                        about_window:setValue("Top", y)
                                        about_window:setValue("Left", x)
                                        about_window:setValue("Status", "show")
									end
								},
                                ui.MenuItem:new{
                                    Width = 70,
                                    Style = "text-align: center;",
									Text = "Quit",
									onClick = function(self)
										self.Application:setValue("Status", "quit")
									end
								}
                            }
                        },
                        ui.MenuItem:new {
                            Width = 70,
							Text = "Plugins",
                            Style = "text-align: center;",
							Children = plugin_entries
                        }
                    }
                },
                ui.Group:new{
                    Style = "margin: 15;",
                    Orientation = "vertical",
                    Children = {
                        ui.Group:new{
                            Width = "free",
                            Orientation = "horizontal",
                            Style = "margin-bottom: 10;",
                            Children = {
                                ui.Text:new{
                                    Id = "current_activity_text",
                                    Class = "caption",
                                    Text = "No Activity",
                                    Style = "text-align: left; font: ui-menu:20;/b;"
                                },
                                ui.Area:new{
                                    Width = "fill",
                                    Height = "auto"
                                },
                                ui.Button:new{
                                    Id = "stop_tracking_button",
                                    Width = 120,
                                    Disabled = true,
                                    Text = "Stop Tracking",
                                    onPress = function(self)
                                        if not self.Pressed then
                                            return
                                        end

                                        report_error(stop_task())
                                        _refresh()
                                    end
                                }
                            }
                        },
                        ui.Text:new{
                            Width = 120,
                            Class = "caption",
                            Text = "Start new activity",
                            Style = "font: 24/b;"
                        },
                        ui.Group:new{
                            Orientation = "horizontal",
                            Style = "margin-bottom: 10;",
                            Children = {
                                task_autocomplete,
                                project_autocomplete,
                                ui.Button:new{
                                    Width = 120,
                                    Id = "start_tracking_button",
                                    Style = "margin-left: 5;",
                                    Text = "Start Tracking",
                                    onPress = function(self)
                                        if not self.Pressed then
                                            return
                                        end

                                        local description_element = self:getById(
                                            "task-description"
                                        )
                                        if description_element.Child.Child.Class == "placeholder" then
                                            -- Report error and abort
                                            notification_window.display(
                                                "Cannot create task: Description field is empty"
                                            )
                                            return
                                        end
                                        local description = description_element:getText()

                                        local project_element = self:getById("task-project")
                                        if project_element.Child.Child.Class == "placeholder" then
                                            -- Report error and abort
                                            notification_window.display(
                                                "Cannot create task: Project field is empty"
                                            )
                                            return
                                        end
                                        local project = project_element:getText()

                                        report_error(add_task(description, project))

                                        -- Clear inputs and refresh UI

                                        InputWithPlaceholder.reset(description_element)
                                        InputWithPlaceholder.reset(project_element)

                                        _refresh()
                                    end
                                }
                            }
                        },
                        ui.Text:new{
                            Width = 60,
                            Class = "caption",
                            Text = "Today",
                            Style = "font: 24/b;"
                        },
                        ui.ScrollGroup:new{
                            Width = "fill",
                            --HSliderMode = "auto",
                            VSliderMode = "auto",
                            Style = "margin-bottom: 20;",
                            Child = ui.Canvas:new{
                                AutoWidth = true,
                                AutoHeight = true,
                                Child = ui.Group:new{
                                    Id = "task_list_group",
                                    Class = "task_list",
                                    Orientation = "vertical",
                                    Children = {}
                                }
                            }
                        },
                        ui.Group:new{
                            Orientation = "horizontal",
                            Width = "free",
                            Children = {
                                ui.Text:new{
                                    Id = "total_time_text",
                                    Width = 100,
                                    Class = "caption",
                                    Text = "No Records Today"
                                },
                                ui.Area:new{
                                    Width = "fill",
                                    Height = "auto"
                                },
                                ui.Button:new{
                                    Id = "export_xml_btn",
                                    Width = 120,
                                    Text = "XML Export"
                                },
                                ui.Button:new{
                                    Id = "export_csv_btn",
                                    Width = 120,
                                    Text = "CSV Export"
                                },
                                ui.Button:new{
                                    Width = 120,
                                    Text = "Show Overview",
                                    onPress = function(self)
                                        local _, _, x, y = self.Window.Drawable:getAttrs()

                                        -- Archor to the main window position
                                        local opening_window = self:getById("stats_window")
                                        opening_window:setValue("Top", y)
                                        opening_window:setValue("Left", x)

                                        opening_window:setValue("Status", "show")
                                        stats_window.update(self)
                                    end
                                }
                            }
                        }
                    }
                }
            }
        }

        this_window:addInputHandler(ui.MSG_FOCUS, this_window, function(self, msg)
            -- Hide autocomplete popups when the window is not in focus
            local is_focused = msg[3] == 1
            if not is_focused then
                task_autocomplete:endPopup()
                project_autocomplete:endPopup()
            end
        end)

        this_window:addInputHandler(ui.MSG_KEYDOWN, this_window, function(self, msg)
            -- Delete Pressed
            if msg[3] == 127 then
                local selected_task = TaskRow.get_selection()
                if selected_task.task_id then
                    report_error(delete_task(selected_task.task_id))
                    _refresh()
                end
            end
        end)

        this_window:addInputHandler(ui.MSG_CLOSE, this_window, function(self, msg)
            this_window.Application:quit()
        end)

        return this_window
    end
}
