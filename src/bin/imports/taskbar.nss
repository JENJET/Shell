menu(type="taskbar" /*vis=key.shift() or key.rbutton()*/ pos=0 title='关于 '+app.name image=\uE249)
{
	item(title="配置" image=\uE10A cmd='"@app.cfg"')
	item(title="管理" image=\uE0F3 admin cmd='"@app.exe"')
	item(title="目录" image=\uE0E8 cmd='"@app.dir"')
	item(title="版本\t"+@app.ver vis=label col=1)
	item(title="指南" image=\uE1C4 cmd='https://nilesoft.org/docs')
	item(title="捐赠" image=\uE1A7 cmd='https://nilesoft.org/donate')
}
menu(where=@(this.count == 0) type='taskbar' image=icon.settings expanded=true)
{
	menu(title="应用" image=\uE254)
	{
		item(title='画图' image=\uE116 cmd='mspaint')
		item(title='计算器' image=\ue1e7 cmd='calc.exe')
		item(title='Edge浏览器' image cmd='@sys.prog32\Microsoft\Edge\Application\msedge.exe')
		item(title=str.res('regedit.exe,-16') image cmd='regedit.exe')
	}
	menu(title="窗口" image=\uE1FB)
	{
		item(title="层叠" cmd=command.cascade_windows)
		item(title="平铺" cmd=command.Show_windows_stacked)
		item(title="并排" cmd=command.Show_windows_side_by_side)
		sep
		item(title='最小化所有' cmd=command.minimize_all_windows)
		item(title='还原所有' cmd=command.restore_all_windows)
	}
	item(title=title.desktop image=icon.desktop cmd=command.toggle_desktop)
	item(title=title.settings image=icon.settings(auto, image.color1) cmd='ms-settings:')
	item(title='任务管理器' sep=both image=icon.task_manager cmd='taskmgr.exe')
	item(title='任务栏设置' sep=both image=inherit cmd='ms-settings:taskbar')
	item(/*vis=key.shift() */title='重启资源管理器' image=\uE251 cmd=command.restart_explorer)
}