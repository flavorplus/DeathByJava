package com.riverbed.test.DeathByJava.web;

import com.riverbed.test.DeathByJava.service.DeathByJavaService;

import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.stereotype.Controller;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.ResponseBody;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.ui.Model;

@Controller
public class DeatByJavaController {

	@Autowired
	private DeathByJavaService deathByJavaService;

	@GetMapping("/")
	@ResponseBody
	public String generateLoad(@RequestParam(name="n", required=false, defaultValue="100") Integer number, Model model) {
		model.addAttribute("number", number);
		return this.deathByJavaService.createLoad(number);
	}
}
