$(function(){
  var form = $(".create-user-form");
  form.submit(function(event){
  	var userName = form.find("input[name='userName']").val();
  	var phoneNumber = form.find("input[name='phoneNumber']").val();
  	$.post("/users", {userName: userName, phoneNumber: phoneNumber}).then(function(){
  		location.reload();
  	}, function(err){
  		console.log(err);
  		alert((err.responseJSON || {}).message);
  	});
  	event.preventDefault();
  });
});
